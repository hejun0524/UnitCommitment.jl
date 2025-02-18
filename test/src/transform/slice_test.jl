# UnitCommitment.jl: Optimization Package for Security-Constrained Unit Commitment
# Copyright (C) 2020, UChicago Argonne, LLC. All rights reserved.
# Released under the modified BSD license. See COPYING.md for more details.

using UnitCommitment, LinearAlgebra, HiGHS, JuMP, JSON, GZip

function transform_slice_test()
    @testset "slice" begin
        instance = UnitCommitment.read(fixture("case14.json.gz"))
        modified = UnitCommitment.slice(instance, 1:2)
        sc = modified.scenarios[1]

        # Should update all time-dependent fields
        @test modified.time == 2
        @test length(sc.power_balance_penalty) == 2
        @test length(sc.reserves_by_name["r1"].amount) == 2
        for u in sc.thermal_units
            @test length(u.max_power) == 2
            @test length(u.min_power) == 2
            @test length(u.must_run) == 2
            @test length(u.min_power_cost) == 2
            for s in u.cost_segments
                @test length(s.mw) == 2
                @test length(s.cost) == 2
            end
        end
        for b in sc.buses
            @test length(b.load) == 2
        end
        for l in sc.lines
            @test length(l.normal_flow_limit) == 2
            @test length(l.emergency_flow_limit) == 2
            @test length(l.flow_limit_penalty) == 2
        end
        for ps in sc.price_sensitive_loads
            @test length(ps.demand) == 2
            @test length(ps.revenue) == 2
        end

        # Should be able to build model without errors
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            "log_to_console" => false,
        )
        model = UnitCommitment.build_model(
            instance = modified,
            optimizer = optimizer,
            variable_names = true,
        )
    end

    @testset "slice profiled units" begin
        instance = UnitCommitment.read(fixture("case14-profiled.json.gz"))
        modified = UnitCommitment.slice(instance, 1:2)
        sc = modified.scenarios[1]

        # Should update all time-dependent fields
        for pu in sc.profiled_units
            @test length(pu.max_power) == 2
            @test length(pu.min_power) == 2
        end

        # Should be able to build model without errors
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            "log_to_console" => false,
        )
        model = UnitCommitment.build_model(
            instance = modified,
            optimizer = optimizer,
            variable_names = true,
        )
    end

    @testset "slice storage units" begin
        instance = UnitCommitment.read(fixture("case14-storage.json.gz"))
        modified = UnitCommitment.slice(instance, 2:4)
        sc = modified.scenarios[1]

        # Should update all time-dependent fields
        for su in sc.storage_units
            @test length(su.min_level) == 3
            @test length(su.max_level) == 3
            @test length(su.simultaneous_charge_and_discharge) == 3
            @test length(su.charge_cost) == 3
            @test length(su.discharge_cost) == 3
            @test length(su.charge_efficiency) == 3
            @test length(su.discharge_efficiency) == 3
            @test length(su.loss_factor) == 3
            @test length(su.min_charge_rate) == 3
            @test length(su.max_charge_rate) == 3
            @test length(su.min_discharge_rate) == 3
            @test length(su.max_discharge_rate) == 3
        end

        # Should be able to build model without errors
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            "log_to_console" => false,
        )
        model = UnitCommitment.build_model(
            instance = modified,
            optimizer = optimizer,
            variable_names = true,
        )
    end

    @testset "slice interfaces" begin
        instance = UnitCommitment.read(fixture("case14-interface.json.gz"))
        modified = UnitCommitment.slice(instance, 1:3)
        sc = modified.scenarios[1]

        # Should update all time-dependent fields
        for ifc in sc.interfaces
            @test length(ifc.net_flow_upper_limit) == 3
            @test length(ifc.net_flow_lower_limit) == 3
            @test length(ifc.flow_limit_penalty) == 3
        end

        # Should be able to build model without errors
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            "log_to_console" => false,
        )
        model = UnitCommitment.build_model(
            instance = modified,
            optimizer = optimizer,
            variable_names = true,
        )
    end
end
