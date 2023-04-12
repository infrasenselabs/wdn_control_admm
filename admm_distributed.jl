#################### LOAD DEPENDENCIES ####################

### load dependencies for main worker
using Distributed
using SharedArrays
using LaTeXStrings
using Statistics
using Plots

# OPENBLAS_NUM_THREADS = 1
addprocs(7)
# addprocs(3)

### instantiate and precompile environment
@everywhere begin
    using Pkg; Pkg.activate(".")
    Pkg.instantiate(); Pkg.precompile()
end

### load dependencies for local workers
@everywhere begin
    using FileIO
    using JLD2
    include("src/admm_functions.jl")
end



#################### PRELIMINARIES ####################

### input problem parameters ###
@everywhere begin
    # net_name = "bwfl_2022_05_hw"
    # net_name = "modena"
    net_name = "L_town"
    # net_name = "bwkw_mod"

    # make_data = true
    make_data = false
    # bv_open = true
    bv_open = false

    n_v = 3
    n_f = 4
    αmax = 25
    δmax = 10
    umin = 0.2
    pmin = 15
    # pmin = 10 # for bwkw network
    ρ = 50
    obj_type = "azp-scc" # obj_type = "pv"; obj_type = "azp-scc"
    pv_type = "range" # pv_type = "variation"; pv_type = "variability"; pv_type = "range"; pv_type = "none"

    scc_time = collect(38:42) # bwfl (peak)
    # scc_time = collect(28:32) # bwkw (peak)
    # scc_time = collect(12:16) # bwfl (min)
    # scc_time = collect(7:8) # modena (peak)
    # scc_time = collect(3:4) # modena (min)
    # scc_time = []
end

### make network and problem data ###
begin
    if make_data
        using OpWater
        # load network data
        if net_name == "bwfl_2022_05_hw"
            load_name = "bwfl_2022_05/hw"
        else
            load_name = net_name
        end
        network = load_network(load_name, afv_idx=false, dbv_idx=false, pcv_idx=false, bv_open=bv_open)

        # make optimization parameters
        opt_params = make_prob_data(network; αmax_mul=αmax, umin=umin, ρ=ρ, pmin=pmin)
        q_init, h_init, err, iter = hydraulic_simulation(network, opt_params)
        S = (π * (network.D) .^ 2) / 4
        v0 = q_init ./ (1000 * S) 
        max_v = ceil(maximum(abs.(v0)))
        opt_params.Qmin , opt_params.Qmax, opt_params.umax = q_bounds_from_u(network, q_init; max_v=max_v)

        # load pcv and afv locations
        @load "data/single_objective_results/"*net_name*"_azp_nv_"*string(n_v)*"_nf_"*string(n_f)*".jld2" sol_best
        v_loc = sol_best.v
        @load "data/single_objective_results/"*net_name*"_scc_nv_"*string(n_v)*"_nf_"*string(n_f)*".jld2" sol_best
        y_loc = sol_best.y

        # save problem data
        make_object_data(net_name, network, opt_params, v_loc, y_loc)
    end
end


### load problem data for distributed.jl version ###
@everywhere begin
    data = load("data/problem_data/"*net_name*"_nv_"*string(n_v)*"_nf_"*string(n_f)*".jld2")
end



#################### ADMM ALGORITHM ####################

### define ADMM parameters and starting values ###
# - primal variable, x := [q, h, η, α]
# - auxiliary (coupling) variable, z := h
# - dual variable λ
# - regularisation parameter γ
# - convergence tolerance ϵ

begin
    np = data["np"]
    nn = data["nn"]
    nt = data["nt"]

    # initialise variables
    xk_0 = SharedArray(vcat(data["q_init"], data["h_init"], zeros(np, nt), zeros(nn, nt)))
    zk = SharedArray(data["h_init"])
    λk = SharedArray(zeros(data["nn"], data["nt"]))
    @everywhere γk = 0.01 # regularisation term
    @everywhere γ0 = 0 # regularisation term for first admm iteration

    # ADMM parameters
    kmax = 1000
    ϵ = 2e-1
    obj_hist = SharedArray(zeros(kmax, nt))
    xk = SharedArray(zeros(np+nn+np+nn, nt))
    z_hist = Array{Union{Nothing, Float64}}(nothing, nn*nt, kmax+1)
    z_hist[:, 1] = vec(zk)
    x_hist = Array{Union{Nothing, Float64}}(nothing, (2*np+2*nn)*nt, kmax+1)
    x_hist[:, 1] = vec(xk_0)
    p_residual = []
    d_residual = []
    iter_f = []

end

### main ADMM loop ###
begin
    cpu_time = @elapsed begin
        for k ∈ collect(1:kmax)

            ### update (in parallel) primal variable xk_t ###

            # set regularisation parameter γ
            if k == 1
                @everywhere γ = γ0
            else
                @everywhere γ = γk
            end
            @sync @distributed for t ∈ collect(1:nt)
                xk[:, t], obj_hist[k, t], status = primal_update(xk_0[:, t], zk[:, t], λk[:, t], data, γ, t, scc_time; ρ=ρ, umin=umin, δmax=δmax)
                if status != 0
                    resto = true
                    xk[:, t], obj_hist[k, t], status = primal_update(xk_0[:, t], zk[:, t], λk[:, t], data, γ, t, scc_time; ρ=ρ, umin=umin, δmax=δmax, resto=resto)
                    if status != 0
                        error("IPOPT did not converge at time step t = $t.")
                    end
                end
            end

            ### save xk data ###
            xk_0 = xk
            x_hist[:, k+1] = vec(xk)

            ### update auxiliary variable zk ###
            zk = auxiliary_update(xk_0, zk, λk, data, γk, pv_type; δmax=δmax)
            z_hist[:, k+1] = vec(zk)

            ### update dual variable λk ###
            hk = xk_0[np+1:np+nn, :]
            λk = λk + γk.*(hk - zk)
            # λk[findall(x->x .< 0, λk)] .= 0

            ### compute residuals ### 
            p_residual_k = maximum(abs.(hk - zk))
            push!(p_residual, p_residual_k)
            d_residual_k = maximum(abs.(z_hist[:, k+1] - z_hist[:, k]))
            push!(d_residual, d_residual_k)

            ### ADMM status statement ###
            if p_residual[k] ≤ ϵ && d_residual[k] ≤ ϵ
                iter_f = k
                @info "ADMM successful at iteration $k of $kmax. Primal residual = $p_residual_k, Dual residual = $d_residual_k. Algorithm terminated."
                break
            else
                iter_f = k
                @info "ADMM unsuccessful at iteration $k of $kmax. Primal residual = $p_residual_k, Dual residual = $d_residual_k. Moving to next iteration."
            end

        end
    end

    objk = obj_hist[iter_f, :]
    xk_0 = reshape(x_hist[:, 2], 2*np+2*nn, nt)
end



### compute objective function (time series) ### 
begin
    if iter_f == kmax
        f_val = Inf
        f_azp = Inf
        f_azp_pv = Inf
        f_scc = Inf
        f_scc_pv = Inf
        cpu_time = Inf
    else
        qk_0 = xk_0[1:np, :]
        qk = xk[1:np, :]
        hk_0 = xk_0[np+1:np+nn, :]
        hk = xk[np+1:np+nn, :]
        A = 1 ./ ((π/4).*data["D"].^2)
        f_val = zeros(nt)
        f_azp = zeros(nt)
        f_azp_pv = zeros(nt)
        f_scc = zeros(nt)
        f_scc_pv = zeros(nt)
        for k ∈ 1:nt
            f_azp[k] = sum(data["azp_weights"][i]*(hk_0[i, k] - data["elev"][i]) for i ∈ 1:nn)
            f_azp_pv[k] = sum(data["azp_weights"][i]*(hk[i, k] - data["elev"][i]) for i ∈ 1:nn)
            f_scc[k] = sum(data["scc_weights"][j]*((1+exp(-ρ*((qk_0[j, k]/1000*A[j]) - umin)))^-1 + (1+exp(-ρ*(-(qk_0[j, k]/1000*A[j]) - umin)))^-1) for j ∈ 1:np)
            f_scc_pv[k] = sum(data["scc_weights"][j]*((1+exp(-ρ*((qk[j, k]/1000*A[j]) - umin)))^-1 + (1+exp(-ρ*(-(qk[j, k]/1000*A[j]) - umin)))^-1) for j ∈ 1:np)
            if k ∈ scc_time
                f_val[k] = f_scc_pv[k]*-1
            else
                f_val[k] = f_azp_pv[k]
            end
        end
    end
end

### load data ###
# begin
#     @load "data/admm_results/"*net_name*"_"*pv_type*"_delta_"*string(δmax)*"_gamma_"*string(γk)*"_distributed.jld2"  xk x_hist obj_hist iter_f p_residual d_residual cpu_time
# end

### save data ###
begin
    @save "data/admm_results/"*net_name*"_"*pv_type*"_delta_"*string(δmax)*"_gamma_"*string(γk)*"_distributed.jld2" nt np nn xk xk_0 objk p_residual d_residual cpu_time f_azp f_azp_pv f_scc f_scc_pv f_val 
end

### load data ###
begin
    @load "data/admm_results/"*net_name*"_"*pv_type*"_delta_"*string(δmax)*"_gamma_"*string(γk)*"_distributed.jld2"  nt np nn xk xk_0 objk p_residual d_residual cpu_time f_azp f_azp_pv f_scc f_scc_pv f_val 
end


### plot residuals ###
begin
    # PyPlot.rc("text", usetex=true)
    # PyPlot.rc("font", family="CMU Serif")
    plot_p_residual = plot()
    plot_p_residual = plot!(collect(1:length(p_residual)), p_residual, c=:red3, markerstrokewidth=0, markeralpha=1, seriestype=:scatter, markersize=5)
    plot_p_residual = plot!(xlabel="", ylabel="Primal residual [m]", ylims=(0, 10), xlims=(0, 100), xtickfontsize=14, ytickfontsize=14, xguidefontsize=16, yguidefontsize=16, legendfont=14, legend=:none, fontfamily="Computer Modern", bottom_margin=4*Plots.mm, size=(600, 600))
    plot_d_residual = plot()
    plot_d_residual = plot!(collect(1:length(d_residual)), d_residual, c=:red3, markerstrokewidth=0, markeralpha=1, seriestype=:scatter, markersize=5)
    plot_d_residual = plot!(xlabel="ADMM iteration", ylabel="Dual residual [m]", ylims=(0, 10), xlims=(0, 100), xtickfontsize=14, ytickfontsize=14, xguidefontsize=16, yguidefontsize=16, legendfont=14, legend=:none, fontfamily="Computer Modern", size=(600, 600))
    plot(plot_p_residual, plot_d_residual, layout = (2, 1), right_margin=4*Plots.mm)
end


### plot objective function (time series) ### 
begin
    plot_azp = plot()
    plot_azp = plot!(collect(1:nt), f_azp_pv, c=:red3, seriestype=:line, linewidth=2, label="with PV")
    plot_azp = plot!(collect(1:nt), f_azp, c=:red3, seriestype=:line, linewidth=2, linestyle=:dash, label="without PV")
    plot_azp = vspan!([scc_time[1], scc_time[end]], c=:black, alpha = 0.1, label = "SCC period")
    # plot_azp = plot!(xlabel="", ylabel="AZP [m]",  xlims=(0, 24), xtickfontsize=14, ytickfontsize=14, xguidefontsize=14, yguidefontsize=14, legendfont=12, legendborder=:false, legend=:best, bottom_margin=2*Plots.mm, size=(600, 550))
    plot_azp = plot!(xlabel="", ylabel="AZP [m]",  xlims=(0, 96), xticks=(0:24:96), xtickfontsize=14, ytickfontsize=14, xguidefontsize=14, yguidefontsize=16, legendfont=14, legendborder=:false, legend=:best, bottom_margin=2*Plots.mm, fontfamily="Computer Modern", size=(600, 600))
    plot_scc = plot()
    plot_scc = plot!(collect(1:nt), f_scc_pv, c=:red3, seriestype=:line, linewidth=2, label="with PV")
    plot_scc = plot!(collect(1:nt), f_scc, c=:red3, seriestype=:line, linewidth=2, linestyle=:dash, label="without PV")
    plot_scc = vspan!([scc_time[1], scc_time[end]], c=:black, alpha = 0.1, label = "SCC period")
    # plot_scc = plot!(xlabel="Time step", ylabel=L"SCC $[\%]$", xlims=(0, 24), xtickfontsize=14, ytickfontsize=14, xguidefontsize=14, yguidefontsize=14, legendfont=12, legend=:none, size=(600, 550))
    plot_scc = plot!(xlabel="Time step", ylabel="SCC [%]", xlims=(0, 96), xticks=(0:24:96), xtickfontsize=14, ytickfontsize=14, xguidefontsize=16, yguidefontsize=16, legendfont=14, legend=:none, fontfamily="Computer Modern", size=(600, 600))
    plot(plot_azp, plot_scc, layout=(2, 1))

    # ylims=(30, 55)
    # ylims=(0, 50)
    # xticks=(0:24:96)
    # size=(425, 500)
end


### pressure heads (optimal dfc) ###
begin
    t = 75 # time step
    node_key = "pressure head"
    p = hk .- data["elev"]
    # p = network.elev
    node_values = vcat(p[:, t], repeat([0.0], network.n0))
    network.pcv_loc = data["v_loc"]
    network.afv_loc = data["y_loc"]
    plot_network_nodes(network, node_values=node_values, node_key=node_key, clims=(0, 80))
    plot_network_layout(network, pipes=false, reservoirs=true, pcvs=true, afvs=true, legend=false)
end


### maximum pipe flow velocities (optimal dfc) ###
begin
    edge_key = "velocity"
    A = 1 ./ ((π/4).*data["D"].^2)
    v = qk ./ 1000 .* A
    edge_values = maximum(v, dims=2)
    network.pcv_loc = data["v_loc"]
    network.afv_loc = data["y_loc"]
    plot_network_edges(network, edge_values=edge_values, edge_key=edge_key, clims=(0, 0.4))
    plot_network_layout(network, pipes=false, reservoirs=true, pcvs=true, afvs=true, legend=false)
end

