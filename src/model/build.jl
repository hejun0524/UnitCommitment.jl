# UnitCommitment.jl: Optimization Package for Security-Constrained Unit Commitment
# Copyright (C) 2020, UChicago Argonne, LLC. All rights reserved.
# Released under the modified BSD license. See COPYING.md for more details.

using JuMP, MathOptInterface, DataStructures
import JuMP: value, fix, set_name

"""
    function build_model(;
        instance::UnitCommitmentInstance,
        isf::Union{Matrix{Float64},Nothing} = nothing,
        lodf::Union{Matrix{Float64},Nothing} = nothing,
        isf_cutoff::Float64 = 0.005,
        lodf_cutoff::Float64 = 0.001,
        optimizer = nothing,
        variable_names::Bool = false,
    )::JuMP.Model

Build the JuMP model corresponding to the given unit commitment instance.

Arguments
=========
- `instance::UnitCommitmentInstance`:
    the instance.
- `isf::Union{Matrix{Float64},Nothing} = nothing`:
    the injection shift factors matrix. If not provided, it will be computed.
- `lodf::Union{Matrix{Float64},Nothing} = nothing`: 
    the line outage distribution factors matrix. If not provided, it will be
    computed.
- `isf_cutoff::Float64 = 0.005`: 
    the cutoff that should be applied to the ISF matrix. Entries with magnitude
    smaller than this value will be set to zero.
- `lodf_cutoff::Float64 = 0.001`: 
    the cutoff that should be applied to the LODF matrix. Entries with magnitude
    smaller than this value will be set to zero.
- `optimizer = nothing`:
    the optimizer factory that should be attached to this model (e.g. Cbc.Optimizer).
    If not provided, no optimizer will be attached.
- `variable_names::Bool = false`: 
    If true, set variable and constraint names. Important if the model is going
    to be exported to an MPS file. For large models, this can take significant
    time, so it's disabled by default.

Example
=======
```jldoctest
julia> import Cbc, UnitCommitment
julia> instance = UnitCommitment.read_benchmark("matpower/case118/2017-02-01")
julia> model = UnitCommitment.build_model(
    instance=instance,
    optimizer=Cbc.Optimizer,
    variable_names=true,
)
```
"""
function build_model(;
    instance::UnitCommitmentInstance,
    isf::Union{Matrix{Float64},Nothing} = nothing,
    lodf::Union{Matrix{Float64},Nothing} = nothing,
    isf_cutoff::Float64 = 0.005,
    lodf_cutoff::Float64 = 0.001,
    optimizer = nothing,
    variable_names::Bool = false,
)::JuMP.Model
    if length(instance.buses) == 1
        isf = zeros(0, 0)
        lodf = zeros(0, 0)
    else
        if isf === nothing
            @info "Computing injection shift factors..."
            time_isf = @elapsed begin
                isf = UnitCommitment._injection_shift_factors(
                    lines = instance.lines,
                    buses = instance.buses,
                )
            end
            @info @sprintf("Computed ISF in %.2f seconds", time_isf)

            @info "Computing line outage factors..."
            time_lodf = @elapsed begin
                lodf = UnitCommitment._line_outage_factors(
                    lines = instance.lines,
                    buses = instance.buses,
                    isf = isf,
                )
            end
            @info @sprintf("Computed LODF in %.2f seconds", time_lodf)

            @info @sprintf(
                "Applying PTDF and LODF cutoffs (%.5f, %.5f)",
                isf_cutoff,
                lodf_cutoff
            )
            isf[abs.(isf).<isf_cutoff] .= 0
            lodf[abs.(lodf).<lodf_cutoff] .= 0
        end
    end

    @info "Building model..."
    time_model = @elapsed begin
        model = Model()
        if optimizer !== nothing
            set_optimizer(model, optimizer)
        end
        model[:obj] = AffExpr()
        model[:instance] = instance
        model[:isf] = isf
        model[:lodf] = lodf
        for field in [
            :prod_above,
            :segprod,
            :reserve,
            :is_on,
            :switch_on,
            :switch_off,
            :net_injection,
            :curtail,
            :overflow,
            :loads,
            :startup,
            :eq_startup_choose,
            :eq_startup_restrict,
            :eq_segprod_limit,
            :eq_prod_above_def,
            :eq_prod_limit,
            :eq_binary_link,
            :eq_switch_on_off,
            :eq_ramp_up,
            :eq_ramp_down,
            :eq_startup_limit,
            :eq_shutdown_limit,
            :eq_min_uptime,
            :eq_min_downtime,
            :eq_power_balance,
            :eq_net_injection_def,
            :eq_min_reserve,
            :expr_inj,
            :expr_reserve,
            :expr_net_injection,
        ]
            model[field] = OrderedDict()
        end
        for lm in instance.lines
            _add_transmission_line!(model, lm)
        end
        for b in instance.buses
            _add_bus!(model, b)
        end
        for g in instance.units
            _add_unit!(model, g)
        end
        for ps in instance.price_sensitive_loads
            _add_price_sensitive_load!(model, ps)
        end
        _build_net_injection_eqs!(model)
        _build_reserve_eqs!(model)
        _build_obj_function!(model)
    end
    @info @sprintf("Built model in %.2f seconds", time_model)

    if variable_names
        _set_names!(model)
    end

    return model
end

function _add_transmission_line!(model, lm)
    obj, T = model[:obj], model[:instance].time
    overflow = model[:overflow]
    for t in 1:T
        v = overflow[lm.name, t] = @variable(model, lower_bound = 0)
        add_to_expression!(obj, v, lm.flow_limit_penalty[t])
    end
end

function _add_bus!(model::JuMP.Model, b::Bus)
    mip = model
    net_injection = model[:expr_net_injection]
    reserve = model[:expr_reserve]
    curtail = model[:curtail]
    for t in 1:model[:instance].time
        # Fixed load
        net_injection[b.name, t] = AffExpr(-b.load[t])

        # Reserves
        reserve[b.name, t] = AffExpr()

        # Load curtailment
        curtail[b.name, t] =
            @variable(mip, lower_bound = 0, upper_bound = b.load[t])
        add_to_expression!(net_injection[b.name, t], curtail[b.name, t], 1.0)
        add_to_expression!(
            model[:obj],
            curtail[b.name, t],
            model[:instance].power_balance_penalty[t],
        )
    end
end

function _add_price_sensitive_load!(model::JuMP.Model, ps::PriceSensitiveLoad)
    mip = model
    loads = model[:loads]
    net_injection = model[:expr_net_injection]
    for t in 1:model[:instance].time
        # Decision variable
        loads[ps.name, t] =
            @variable(mip, lower_bound = 0, upper_bound = ps.demand[t])

        # Objective function terms
        add_to_expression!(model[:obj], loads[ps.name, t], -ps.revenue[t])

        # Net injection
        add_to_expression!(
            net_injection[ps.bus.name, t],
            loads[ps.name, t],
            -1.0,
        )
    end
end

function _add_unit!(model::JuMP.Model, g::Unit)
    mip, T = model, model[:instance].time
    gi, K, S = g.name, length(g.cost_segments), length(g.startup_categories)

    segprod = model[:segprod]
    prod_above = model[:prod_above]
    reserve = model[:reserve]
    startup = model[:startup]
    is_on = model[:is_on]
    switch_on = model[:switch_on]
    switch_off = model[:switch_off]
    expr_net_injection = model[:expr_net_injection]
    expr_reserve = model[:expr_reserve]

    if !all(g.must_run) && any(g.must_run)
        error("Partially must-run units are not currently supported")
    end

    if g.initial_power === nothing || g.initial_status === nothing
        error("Initial conditions for $(g.name) must be provided")
    end

    is_initially_on = (g.initial_status > 0 ? 1.0 : 0.0)

    # Decision variables
    for t in 1:T
        for k in 1:K
            segprod[gi, t, k] = @variable(model, lower_bound = 0)
        end
        prod_above[gi, t] = @variable(model, lower_bound = 0)
        if g.provides_spinning_reserves[t]
            reserve[gi, t] = @variable(model, lower_bound = 0)
        else
            reserve[gi, t] = 0.0
        end
        for s in 1:S
            startup[gi, t, s] = @variable(model, binary = true)
        end
        if g.must_run[t]
            is_on[gi, t] = 1.0
            switch_on[gi, t] = (t == 1 ? 1.0 - is_initially_on : 0.0)
            switch_off[gi, t] = 0.0
        else
            is_on[gi, t] = @variable(model, binary = true)
            switch_on[gi, t] = @variable(model, binary = true)
            switch_off[gi, t] = @variable(model, binary = true)
        end
    end

    for t in 1:T
        # Time-dependent start-up costs
        for s in 1:S
            # If unit is switching on, we must choose a startup category
            model[:eq_startup_choose][gi, t, s] = @constraint(
                mip,
                switch_on[gi, t] == sum(startup[gi, t, s] for s in 1:S)
            )

            # If unit has not switched off in the last `delay` time periods, startup category is forbidden.
            # The last startup category is always allowed.
            if s < S
                range_start = t - g.startup_categories[s+1].delay + 1
                range_end = t - g.startup_categories[s].delay
                range = (range_start:range_end)
                initial_sum = (
                    g.initial_status < 0 && (g.initial_status + 1 in range) ? 1.0 : 0.0
                )
                model[:eq_startup_restrict][gi, t, s] = @constraint(
                    mip,
                    startup[gi, t, s] <=
                    initial_sum +
                    sum(switch_off[gi, i] for i in range if i >= 1)
                )
            end

            # Objective function terms for start-up costs
            add_to_expression!(
                model[:obj],
                startup[gi, t, s],
                g.startup_categories[s].cost,
            )
        end

        # Objective function terms for production costs
        add_to_expression!(model[:obj], is_on[gi, t], g.min_power_cost[t])
        for k in 1:K
            add_to_expression!(
                model[:obj],
                segprod[gi, t, k],
                g.cost_segments[k].cost[t],
            )
        end

        # Production limits (piecewise-linear segments)
        for k in 1:K
            model[:eq_segprod_limit][gi, t, k] = @constraint(
                mip,
                segprod[gi, t, k] <= g.cost_segments[k].mw[t] * is_on[gi, t]
            )
        end

        # Definition of production
        model[:eq_prod_above_def][gi, t] = @constraint(
            mip,
            prod_above[gi, t] == sum(segprod[gi, t, k] for k in 1:K)
        )

        # Production limit
        model[:eq_prod_limit][gi, t] = @constraint(
            mip,
            prod_above[gi, t] + reserve[gi, t] <=
            (g.max_power[t] - g.min_power[t]) * is_on[gi, t]
        )

        # Binary variable equations for economic units
        if !g.must_run[t]

            # Link binary variables
            if t == 1
                model[:eq_binary_link][gi, t] = @constraint(
                    mip,
                    is_on[gi, t] - is_initially_on ==
                    switch_on[gi, t] - switch_off[gi, t]
                )
            else
                model[:eq_binary_link][gi, t] = @constraint(
                    mip,
                    is_on[gi, t] - is_on[gi, t-1] ==
                    switch_on[gi, t] - switch_off[gi, t]
                )
            end

            # Cannot switch on and off at the same time
            model[:eq_switch_on_off][gi, t] =
                @constraint(mip, switch_on[gi, t] + switch_off[gi, t] <= 1)
        end

        # Ramp up limit
        if t == 1
            if is_initially_on == 1
                model[:eq_ramp_up][gi, t] = @constraint(
                    mip,
                    prod_above[gi, t] + reserve[gi, t] <=
                    (g.initial_power - g.min_power[t]) + g.ramp_up_limit
                )
            end
        else
            model[:eq_ramp_up][gi, t] = @constraint(
                mip,
                prod_above[gi, t] + reserve[gi, t] <=
                prod_above[gi, t-1] + g.ramp_up_limit
            )
        end

        # Ramp down limit
        if t == 1
            if is_initially_on == 1
                model[:eq_ramp_down][gi, t] = @constraint(
                    mip,
                    prod_above[gi, t] >=
                    (g.initial_power - g.min_power[t]) - g.ramp_down_limit
                )
            end
        else
            model[:eq_ramp_down][gi, t] = @constraint(
                mip,
                prod_above[gi, t] >= prod_above[gi, t-1] - g.ramp_down_limit
            )
        end

        # Startup limit
        model[:eq_startup_limit][gi, t] = @constraint(
            mip,
            prod_above[gi, t] + reserve[gi, t] <=
            (g.max_power[t] - g.min_power[t]) * is_on[gi, t] -
            max(0, g.max_power[t] - g.startup_limit) * switch_on[gi, t]
        )

        # Shutdown limit
        if g.initial_power > g.shutdown_limit
            model[:eq_shutdown_limit][gi, 0] =
                @constraint(mip, switch_off[gi, 1] <= 0)
        end
        if t < T
            model[:eq_shutdown_limit][gi, t] = @constraint(
                mip,
                prod_above[gi, t] <=
                (g.max_power[t] - g.min_power[t]) * is_on[gi, t] -
                max(0, g.max_power[t] - g.shutdown_limit) * switch_off[gi, t+1]
            )
        end

        # Minimum up-time
        model[:eq_min_uptime][gi, t] = @constraint(
            mip,
            sum(switch_on[gi, i] for i in (t-g.min_uptime+1):t if i >= 1) <=
            is_on[gi, t]
        )

        # # Minimum down-time
        model[:eq_min_downtime][gi, t] = @constraint(
            mip,
            sum(switch_off[gi, i] for i in (t-g.min_downtime+1):t if i >= 1) <= 1 - is_on[gi, t]
        )

        # Minimum up/down-time for initial periods
        if t == 1
            if g.initial_status > 0
                model[:eq_min_uptime][gi, 0] = @constraint(
                    mip,
                    sum(
                        switch_off[gi, i] for
                        i in 1:(g.min_uptime-g.initial_status) if i <= T
                    ) == 0
                )
            else
                model[:eq_min_downtime][gi, 0] = @constraint(
                    mip,
                    sum(
                        switch_on[gi, i] for
                        i in 1:(g.min_downtime+g.initial_status) if i <= T
                    ) == 0
                )
            end
        end

        # Add to net injection expression
        add_to_expression!(
            expr_net_injection[g.bus.name, t],
            prod_above[g.name, t],
            1.0,
        )
        add_to_expression!(
            expr_net_injection[g.bus.name, t],
            is_on[g.name, t],
            g.min_power[t],
        )

        # Add to reserves expression
        add_to_expression!(expr_reserve[g.bus.name, t], reserve[gi, t], 1.0)
    end
end

function _build_obj_function!(model::JuMP.Model)
    @objective(model, Min, model[:obj])
end

function _build_net_injection_eqs!(model::JuMP.Model)
    T = model[:instance].time
    net_injection = model[:net_injection]
    for t in 1:T, b in model[:instance].buses
        n = net_injection[b.name, t] = @variable(model)
        model[:eq_net_injection_def][t, b.name] =
            @constraint(model, n == model[:expr_net_injection][b.name, t])
    end
    for t in 1:T
        model[:eq_power_balance][t] = @constraint(
            model,
            sum(net_injection[b.name, t] for b in model[:instance].buses) == 0
        )
    end
end

function _build_reserve_eqs!(model::JuMP.Model)
    reserves = model[:instance].reserves
    for t in 1:model[:instance].time
        model[:eq_min_reserve][t] = @constraint(
            model,
            sum(
                model[:expr_reserve][b.name, t] for b in model[:instance].buses
            ) >= reserves.spinning[t]
        )
    end
end

function _set_names!(model::JuMP.Model)
    @info "Setting variable and constraint names..."
    time_varnames = @elapsed begin
        _set_names!(object_dictionary(model))
    end
    @info @sprintf("Set names in %.2f seconds", time_varnames)
end

function _set_names!(dict::Dict)
    for name in keys(dict)
        dict[name] isa AbstractDict || continue
        for idx in keys(dict[name])
            if dict[name][idx] isa AffExpr
                continue
            end
            idx_str = join(map(string, idx), ",")
            set_name(dict[name][idx], "$name[$idx_str]")
        end
    end
end