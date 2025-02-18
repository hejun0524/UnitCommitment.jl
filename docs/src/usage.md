Usage
=====

Installation
------------

UnitCommitment.jl was tested and developed with [Julia 1.9](https://julialang.org/). To install Julia, please follow the [installation guide on the official Julia website](https://julialang.org/downloads/). To install UnitCommitment.jl, run the Julia interpreter, type `]` to open the package manager, then type:

```text
pkg> add UnitCommitment@0.4
```

To solve the optimization models, a mixed-integer linear programming (MILP) solver is also required. Please see the [JuMP installation guide](https://jump.dev/JuMP.jl/stable/installation/) for more instructions on installing a solver. Typical open-source choices are [HiGHS](https://github.com/jump-dev/HiGHS.jl), [Cbc](https://github.com/JuliaOpt/Cbc.jl) and [GLPK](https://github.com/JuliaOpt/GLPK.jl). In the instructions below, HiGHS will be used, but any other MILP solver listed in JuMP installation guide should also be compatible.

Typical Usage
-------------

### Solving user-provided instances

The first step to use UC.jl is to construct JSON files that describe each scenario of your deterministic or stochastic unit commitment instance. See [Data Format](format.md) for a complete description of the data format UC.jl expects. The next steps, as shown below, are to: (1) read the scenario files; (2) build the optimization model; (3) run the optimization; and (4) extract the optimal solution.

```julia
using HiGHS
using JuMP
using UnitCommitment

# 1. Read instance
instance = UnitCommitment.read(["example/s1.json", "example/s2.json"])

# 2. Construct optimization model
model = UnitCommitment.build_model(
    instance=instance,
    optimizer=HiGHS.Optimizer,
)

# 3. Solve model
UnitCommitment.optimize!(model)

# 4. Write solution to a file
solution = UnitCommitment.solution(model)
UnitCommitment.write("example/out.json", solution)
```

To read multiple files from a given folder, the [Glob](https://github.com/vtjnash/Glob.jl) package can be used:

```jldoctest usage1; output = false
using Glob
using UnitCommitment

instance = UnitCommitment.read(glob("s*.json", "example/"))

# output
UnitCommitmentInstance(2 scenarios, 6 thermal units, 0 profiled units, 14 buses, 20 lines, 19 contingencies, 1 price sensitive loads, 4 time steps)
```

To solve deterministic instances, a single scenario file may be provided.

```jldoctest usage1; output = false
instance = UnitCommitment.read("example/s1.json")

# output
UnitCommitmentInstance(1 scenarios, 6 thermal units, 0 profiled units, 14 buses, 20 lines, 19 contingencies, 1 price sensitive loads, 4 time steps)
```

### Solving benchmark instances

UnitCommitment.jl contains a large number of deterministic benchmark instances collected from the literature and converted into a common data format. To solve one of these instances individually, instead of constructing your own, the function `read_benchmark` can be used, as shown below. See [Instances](instances.md) for the complete list of available instances.

```jldoctest usage1; output = false
instance = UnitCommitment.read_benchmark("matpower/case3375wp/2017-02-01")

# output
UnitCommitmentInstance(1 scenarios, 590 thermal units, 0 profiled units, 3374 buses, 4161 lines, 3245 contingencies, 0 price sensitive loads, 36 time steps)
```

## Customizing the formulation

By default, `build_model` uses a formulation that combines modeling components from different publications, and that has been carefully tested, using our own benchmark scripts, to provide good performance across a wide variety of instances. This default formulation is expected to change over time, as new methods are proposed in the literature. You can, however, construct your own formulation, based on the modeling components that you choose, as shown in the next example.

```julia
using HiGHS
using UnitCommitment

import UnitCommitment:
    Formulation,
    KnuOstWat2018,
    MorLatRam2013,
    ShiftFactorsFormulation

instance = UnitCommitment.read_benchmark(
    "matpower/case118/2017-02-01",
)

model = UnitCommitment.build_model(
    instance = instance,
    optimizer = HiGHS.Optimizer,
    formulation = Formulation(
        pwl_costs = KnuOstWat2018.PwlCosts(),
        ramping = MorLatRam2013.Ramping(),
        startup_costs = MorLatRam2013.StartupCosts(),
        transmission = ShiftFactorsFormulation(
            isf_cutoff = 0.005,
            lodf_cutoff = 0.001,
        ),
    ),
)
```

## Generating initial conditions

When creating random unit commitment instances for benchmark purposes, it is often hard to compute, in advance, sensible initial conditions for all thermal generators. Setting initial conditions naively (for example, making all generators initially off and producing no power) can easily cause the instance to become infeasible due to excessive ramping. Initial conditions can also make it hard to modify existing instances. For example, increasing the system load without carefully modifying the initial conditions may make the problem infeasible or unrealistically challenging to solve.

To help with this issue, UC.jl provides a utility function which can generate feasible initial conditions by solving a single-period optimization problem, as shown below:

```julia
using HiGHS
using UnitCommitment

# Read original instance
instance = UnitCommitment.read("example/s1.json")

# Generate initial conditions (in-place)
UnitCommitment.generate_initial_conditions!(instance, HiGHS.Optimizer)

# Construct and solve optimization model
model = UnitCommitment.build_model(
    instance=instance,
    optimizer=HiGHS.Optimizer,
)
UnitCommitment.optimize!(model)
```

!!! warning

    The function `generate_initial_conditions!` may return different initial conditions after each call, even if the same instance and the same optimizer is provided. The particular algorithm may also change in a future version of UC.jl. For these reasons, it is recommended that you generate initial conditions exactly once for each instance and store them for later use.
    
## Verifying solutions

When developing new formulations, it is very easy to introduce subtle errors in the model that result in incorrect solutions. To help avoiding this, UC.jl includes a utility function that verifies if a given solution is feasible, and, if not, prints all the validation errors it found. The implementation of this function is completely independent from the implementation of the optimization model, and therefore can be used to validate it.

```jldoctest; output = false
using JSON
using UnitCommitment

# Read instance
instance = UnitCommitment.read("example/s1.json")

# Read solution (potentially produced by other packages) 
solution = JSON.parsefile("example/out.json")

# Validate solution and print validation errors
UnitCommitment.validate(instance, solution)

# output

true
```

## Progressive Hedging

By default, UC.jl uses the Extensive Form (EF) when solving stochastic instances. This approach involves constructing a single JuMP model that contains data and decision variables for all scenarios. Although EF has optimality guarantees and performs well with small test cases, it can become computationally intractable for large instances or substantial number of scenarios.

Progressive Hedging (PH) is an alternative (heuristic) solution method provided by UC.jl in which the problem is decomposed into smaller scenario-based subproblems, which are then solved in parallel in separate Julia processes, potentially across multiple machines. Quadratic penalty terms are used to enforce convergence of first-stage decision variables. The method is closely related to the Alternative Direction Method of Multipliers (ADMM) and can handle larger instances, although it is not guaranteed to converge to the optimal solution. Our implementation of PH relies on Message Passing Interface (MPI) for communication. We refer to [MPI.jl Documentation](https://github.com/JuliaParallel/MPI.jl) for more details on installing MPI.

The following example shows how to solve SCUC instances using progressive hedging. The script should be saved in a file, say `ph.jl`, and executed using `mpiexec -n <num-scenarios> julia ph.jl`.


```julia
using HiGHS
using MPI
using UnitCommitment
using Glob

# 1. Initialize MPI
MPI.Init()

# 2. Configure progressive hedging method
ph = UnitCommitment.ProgressiveHedging()

# 3. Read problem instance
instance = UnitCommitment.read(["example/s1.json", "example/s2.json"], ph)

# 4. Build JuMP model
model = UnitCommitment.build_model(
    instance = instance,
    optimizer = HiGHS.Optimizer,
)

# 5. Run the decentralized optimization algorithm
UnitCommitment.optimize!(model, ph)

# 6. Fetch the solution
solution = UnitCommitment.solution(model, ph)

# 7. Close MPI
MPI.Finalize()
```

When using PH, the model can be customized as usual, with different formulations or additional user-provided constraints. Note that `read`, in this case, takes `ph` as an argument. This allows each Julia process to read only the instance files that are relevant to it. Similarly, the `solution` function gathers the optimal solution of each processes and returns a combined dictionary. 

Each process solves a sub-problem with $\frac{s}{p}$ scenarios, where $s$ is the total number of scenarios and $p$ is the number of MPI processes. For instance, if we have 15 scenario files and 5 processes, then each process will solve a JuMP model that contains data for 3 scenarios. If the total number of scenarios is not divisible by the number of processes, then an error will be thrown.


!!! warning

    Currently, PH can handle only equiprobable scenarios. Further, `solution(model, ph)` can only handle cases where only one scenario is modeled in each process.


## Computing Locational Marginal Prices

Locational marginal prices (LMPs) refer to the cost of supplying electricity at a particular location of the network. Multiple methods for computing LMPs have been proposed in the literature. UnitCommitment.jl implements two commonly-used methods: conventional LMPs and Approximated Extended LMPs (AELMPs). To compute LMPs for a given unit commitment instance, the `compute_lmp` function can be used, as shown in the examples below. The function accepts three arguments -- a solved SCUC model, an LMP method, and a linear optimizer -- and it returns a dictionary mapping `(bus_name, time)` to the marginal price.


!!! warning

    Most mixed-integer linear optimizers, such as `HiGHS`, `Gurobi` and `CPLEX` can be used with `compute_lmp`, with the notable exception of `Cbc`, which does not support dual value evaluations. If using `Cbc`, please provide `Clp` as the linear optimizer.

### Conventional LMPs

LMPs are conventionally computed by: (1) solving the SCUC model, (2) fixing all binary variables to their optimal values, and (3) re-solving the resulting linear programming model. In this approach, the LMPs are defined as the dual variables' values associated with the net injection constraints. The example below shows how to compute conventional LMPs for a given unit commitment instance. First, we build and optimize the SCUC model. Then, we call the `compute_lmp` function, providing as the second argument `ConventionalLMP()`.


```julia
using UnitCommitment
using HiGHS

import UnitCommitment: ConventionalLMP

# Read benchmark instance
instance = UnitCommitment.read_benchmark("matpower/case118/2018-01-01")

# Build the model
model = UnitCommitment.build_model(
    instance = instance,
    optimizer = HiGHS.Optimizer,
)

# Optimize the model
UnitCommitment.optimize!(model)

# Compute the LMPs using the conventional method
lmp = UnitCommitment.compute_lmp(
    model,
    ConventionalLMP(),
    optimizer = HiGHS.Optimizer,
)

# Access the LMPs
# Example: "s1" is the scenario name, "b1" is the bus name, 1 is the first time slot
@show lmp["s1","b1", 1]
```

### Approximate Extended LMPs

Approximate Extended LMPs (AELMPs) are an alternative method to calculate locational marginal prices which attemps to minimize uplift payments. The method internally works by modifying the instance data in three ways: (1) it sets the minimum power output of each generator to zero, (2) it averages the start-up cost over the offer blocks for each generator, and (3) it relaxes all integrality constraints. To compute AELMPs, as shown in the example below, we call `compute_lmp` and provide `AELMP()` as the second argument.

This method has two configurable parameters: `allow_offline_participation` and `consider_startup_costs`. If `allow_offline_participation = true`, then offline generators are allowed to participate in the pricing. If instead `allow_offline_participation = false`, offline generators are not allowed and therefore are excluded from the system. A solved UC model is optional if offline participation is allowed, but is required if not allowed. The method forces offline participation to be allowed if the UC model supplied by the user is not solved. For the second field, If `consider_startup_costs = true`, then start-up costs are integrated and averaged over each unit production; otherwise the production costs stay the same. By default, both fields are set to `true`.

!!! warning

    This approximation method is still under active research, and has several limitations. The implementation provided in the package is based on MISO Phase I only. It only supports fast start resources. More specifically, the minimum up/down time of all generators must be 1, the initial power of all generators must be 0, and the initial status of all generators must be negative. The method does not support time-varying start-up costs. The method does not support multiple scenarios. If offline participation is not allowed, AELMPs treats an asset to be  offline if it is never on throughout all time periods. 

```julia
using UnitCommitment
using HiGHS

import UnitCommitment: AELMP

# Read benchmark instance
instance = UnitCommitment.read_benchmark("matpower/case118/2017-02-01")

# Build the model
model = UnitCommitment.build_model(
    instance = instance,
    optimizer = HiGHS.Optimizer,
)

# Optimize the model
UnitCommitment.optimize!(model)

# Compute the AELMPs
aelmp = UnitCommitment.compute_lmp(
    model,
    AELMP(
        allow_offline_participation = false,
        consider_startup_costs = true
    ),
    optimizer = HiGHS.Optimizer
)

# Access the AELMPs
# Example: "s1" is the scenario name, "b1" is the bus name, 1 is the first time slot
# Note: although scenario is supported, the query still keeps the scenario keys for consistency.
@show aelmp["s1", "b1", 1]
```

## Time Decomposition

Solving unit commitment instances that have long time horizons (for example, year-long 8760-hour instances) requires a substantial amount of computational power. To address this issue, UC.jl offers a time decomposition method, which breaks the instance down into multiple overlapping subproblems, solves them sequentially, then reassembles the solution.

When solving a unit commitment instance with a dense time slot structure, computational complexity can become a significant challenge. For instance, if the instance contains hourly data for an entire year (8760 hours), solving such a model can require a substantial amount of computational power. To address this issue, UC.jl provides a time_decomposition method within the `optimize!` function. This method decomposes the problem into multiple sub-problems, solving them sequentially.

The `optimize!` function takes 5 parameters: a unit commitment instance, a `TimeDecomposition` method, an optimizer, and two optional functions `after_build` and `after_optimize`. It returns a solution dictionary. The `TimeDecomposition` method itself requires four arguments: `time_window`, `time_increment`, `inner_method` (optional), and `formulation` (optional). These arguments define the time window for each sub-problem, the time increment to move to the next sub-problem, the method used to solve each sub-problem, and the formulation employed, respectively. The two functions, namely `after_build` and `after_optimize`, are invoked subsequent to the construction and optimization of each sub-model, respectively. It is imperative that the `after_build` function requires its two arguments to be consistently mapped to `model` and `instance`, while the `after_optimize` function necessitates its three arguments to be consistently mapped to `solution`, `model`, and `instance`.

The code snippet below illustrates an example of solving an instance by decomposing the model into multiple 36-hour sub-problems using the `XavQiuWanThi2019` method. Each sub-problem advances 24 hours at a time. The first sub-problem covers time steps 1 to 36, the second covers time steps 25 to 60, the third covers time steps 49 to 84, and so on. The initial power levels and statuses of the second and subsequent sub-problems are set based on the results of the first 24 hours from each of their immediate prior sub-problems. In essence, this approach addresses the complexity of solving a large problem by tackling it in 24-hour intervals, while incorporating an additional 12-hour buffer to mitigate the closing window effect for each sub-problem. Furthermore, the `after_build` function imposes the restriction that `g3` and `g4` cannot be activated simultaneously during the initial time slot of each sub-problem. On the other hand, the `after_optimize` function is invoked to calculate the conventional Locational Marginal Prices (LMPs) for each sub-problem, and subsequently appends the computed values to the `lmps` vector.

> **Warning** 
> Specifying `TimeDecomposition` as the value of the `inner_method` field of another `TimeDecomposition` causes errors when calling the `optimize!` function due to the different argument structures between the two `optimize!` functions.

```julia
using UnitCommitment, JuMP, Cbc, HiGHS

import UnitCommitment: 
    TimeDecomposition,
    ConventionalLMP,
    XavQiuWanThi2019,
    Formulation

# specifying the after_build and after_optimize functions
function after_build(model, instance)
    @constraint(
        model,
        model[:is_on]["g3", 1] + model[:is_on]["g4", 1] <= 1,
    )
end

lmps = []
function after_optimize(solution, model, instance)
    lmp = UnitCommitment.compute_lmp(
        model,
        ConventionalLMP(),
        optimizer = HiGHS.Optimizer,
    )
    return push!(lmps, lmp)
end

# assume the instance is given as a 120h problem
instance = UnitCommitment.read("instance.json")

solution = UnitCommitment.optimize!(
    instance,
    TimeDecomposition(
        time_window = 36,  # solve 36h problems
        time_increment = 24,  # advance by 24h each time
        inner_method = XavQiuWanThi2019.Method(),
        formulation = Formulation(),
    ),
    optimizer = Cbc.Optimizer,
    after_build = after_build,
    after_optimize = after_optimize,
)
```

## Day-ahead (DA) Market to Real-time (RT) Markets
The UC.jl package offers a comprehensive set of functions for solving marketing problems. The primary function, `solve_market`, facilitates the solution of day-ahead (DA) markets, which can be either deterministic or stochastic in nature. Subsequently, it sequentially maps the commitment status obtained from the DA market to all the real-time (RT) markets, which are deterministic instances. It is essential to ensure that the time span of the DA market encompasses all the RT markets, and the file paths for the RT markets must be specified in chronological order. Each RT market should represent a single time slot, and it is recommended to include a few additional time slots to mitigate the closing window effect.

The `solve_market` function accepts several parameters, including the file path (or a list of file paths in the case of stochastic markets) for the DA market, a list of file paths for the RT markets, the market settings specified by the `MarketSettings` structure, and an optimizer. The `MarketSettings` structure itself requires three optional arguments: `inner_method`, `lmp_method`, and `formulation`. If the computation of Locational Marginal Prices (LMPs) is not desired, the `lmp_method` can be set to `nothing`. Additional optional parameters include a linear programming optimizer for solving LMPs (if a different optimizer than the required one is desired), callback functions `after_build_da` and `after_optimize_da`, which are invoked after the construction and optimization of the DA market, and callback functions `after_build_rt` and `after_optimize_rt`, which are invoked after the construction and optimization of each RT market. It is crucial to note that the `after_build` function requires its two arguments to consistently correspond to `model` and `instance`, while the `after_optimize` function requires its three arguments to consistently correspond to `solution`, `model`, and `instance`.

As an illustrative example, suppose the DA market predicts hourly data for a 24-hour period, while the RT markets represent 5-minute intervals. In this scenario, each RT market file corresponds to a specific 5-minute interval, with the first RT market representing the initial 5 minutes, the second RT market representing the subsequent 5 minutes, and so on. Consequently, there should be 12 RT market files for each hour. To mitigate the closing window effect, except for the last few RT markets, each RT market should contain three time slots, resulting in a total time span of 15 minutes. However, only the first time slot is considered in the final solution. The last two RT markets should only contain 2 and 1 time slot(s), respectively, to ensure that the total time covered by all RT markets does not exceed the time span of the DA market. The code snippet below demonstrates a simplified example of how to utilize the `solve_market` function. Please note that it only serves as a simplified example and may require further customization based on the specific requirements of your use case.

```julia
using UnitCommitment, Cbc, HiGHS

import UnitCommitment: 
    MarketSettings,
    XavQiuWanThi2019,
    ConventionalLMP,
    Formulation

solution = UnitCommitment.solve_market(
    "da_instance.json",
    ["rt_instance_1.json", "rt_instance_2.json", "rt_instance_3.json"],
    MarketSettings(
        inner_method = XavQiuWanThi2019.Method(),
        lmp_method = ConventionalLMP(),
        formulation = Formulation(),
    ),
    optimizer = Cbc.Optimizer,
    lp_optimizer = HiGHS.Optimizer,
)
```
