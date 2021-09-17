#===================================
Define GNNGraph type as a subtype of LightGraphs' AbstractGraph.
For the core methods to be implemented by any AbstractGraph, see
https://juliagraphs.org/LightGraphs.jl/latest/types/#AbstractGraph-Type
https://juliagraphs.org/LightGraphs.jl/latest/developing/#Developing-Alternate-Graph-Types
=============================================#

const COO_T = Tuple{T, T, V} where {T <: AbstractVector, V}
const ADJLIST_T = AbstractVector{T} where T <: AbstractVector
const ADJMAT_T = AbstractMatrix
const SPARSE_T = AbstractSparseMatrix # subset of ADJMAT_T

""" 
    GNNGraph(data; [graph_type, ndata, edata, gdata, num_nodes, graph_indicator, dir])
    GNNGraph(g::GNNGraph; [ndata, edata, gdata])

A type representing a graph structure and storing also 
feature arrays associated to nodes, edges, and to the whole graph (global features). 

A `GNNGraph` can be constructed out of different objects `data` expressing
the connections inside the graph. The internal representation type
is determined by `graph_type`.

When constructed from another `GNNGraph`, the internal graph representation
is preserved and shared. The node/edge/global features are transmitted
as well, unless explicitely changed though keyword arguments.

A `GNNGraph` can also represent multiple graphs batched togheter 
(see [`Flux.batch`](@ref) or [`SparseArrays.blockdiag`](@ref)).
The field `g.graph_indicator` contains the graph membership
of each node.

A `GNNGraph` is a LightGraphs' `AbstractGraph`, therefore any functionality
from the LightGraphs' graph library can be used on it.

# Arguments 

- `data`: Some data representing the graph topology. Possible type are 
    - An adjacency matrix
    - An adjacency list.
    - A tuple containing the source and target vectors (COO representation)
    - A LightGraphs' graph.
- `graph_type`: A keyword argument that specifies 
                the underlying representation used by the GNNGraph. 
                Currently supported values are 
    - `:coo`. Graph represented as a tuple `(source, target)`, such that the `k`-th edge 
              connects the node `source[k]` to node `target[k]`.
              Optionally, also edge weights can be given: `(source, target, weights)`.
    - `:sparse`. A sparse adjacency matrix representation.
    - `:dense`. A dense adjacency matrix representation.  
    Default `:coo`.
- `dir`. The assumed edge direction when given adjacency matrix or adjacency list input data `g`. 
        Possible values are `:out` and `:in`. Default `:out`.
- `num_nodes`. The number of nodes. If not specified, inferred from `g`. Default `nothing`.
- `graph_indicator`. For batched graphs, a vector containing the graph assigment of each node. Default `nothing`.  
- `ndata`: Node features. A named tuple of arrays whose last dimension has size num_nodes.
- `edata`: Edge features. A named tuple of arrays whose whose last dimension has size num_edges.
- `gdata`: Global features. A named tuple of arrays whose has size num_graphs. 

# Usage. 

```julia
using Flux, GraphNeuralNetworks

# Construct from adjacency list representation
data = [[2,3], [1,4,5], [1], [2,5], [2,4]]
g = GNNGraph(data)

# Number of nodes, edges, and batched graphs
g.num_nodes  # 5
g.num_edges  # 10 
g.num_graphs # 1 

# Same graph in COO representation
s = [1,1,2,2,2,3,4,4,5,5]
t = [2,3,1,4,5,3,2,5,2,4]
g = GNNGraph(s, t)

# From a LightGraphs' graph
g = GNNGraph(erdos_renyi(100, 20))

# Add 2 node feature arrays
g = GNNGraph(g, ndata = (x=rand(100, g.num_nodes), y=rand(g.num_nodes)))

# Add node features and edge features with default names `x` and `e` 
g = GNNGraph(g, ndata = rand(100, g.num_nodes), edata = rand(16, g.num_edges))

g.ndata.x
g.ndata.e

# Send to gpu
g = g |> gpu

# Collect edges' source and target nodes.
# Both source and target are vectors of length num_edges
source, target = edge_index(g)
```
"""
struct GNNGraph{T<:Union{COO_T,ADJMAT_T}}
    graph::T
    num_nodes::Int
    num_edges::Int
    num_graphs::Int
    graph_indicator
    ndata::NamedTuple
    edata::NamedTuple
    gdata::NamedTuple
end

@functor GNNGraph

function GNNGraph(data; 
                        num_nodes = nothing,
                        graph_indicator = nothing, 
                        graph_type = :coo,
                        dir = :out,
                        ndata = (;), 
                        edata = (;), 
                        gdata = (;),
                        )

    @assert graph_type ∈ [:coo, :dense, :sparse] "Invalid graph_type $graph_type requested"
    @assert dir ∈ [:in, :out]
    
    if graph_type == :coo
        g, num_nodes, num_edges = to_coo(data; num_nodes, dir)
    elseif graph_type == :dense
        g, num_nodes, num_edges = to_dense(data; dir)
    elseif graph_type == :sparse
        g, num_nodes, num_edges = to_sparse(data; dir)
    end
    
    num_graphs = !isnothing(graph_indicator) ? maximum(graph_indicator) : 1
    
    ndata = normalize_graphdata(ndata, :x)
    edata = normalize_graphdata(edata, :e)
    gdata = normalize_graphdata(gdata, :u)
    
    GNNGraph(g, 
            num_nodes, num_edges, num_graphs, 
            graph_indicator,
            ndata, edata, gdata)
end

# COO convenience constructors
GNNGraph(s::AbstractVector, t::AbstractVector, v = nothing; kws...) = GNNGraph((s, t, v); kws...)
GNNGraph((s, t)::NTuple{2}; kws...) = GNNGraph((s, t, nothing); kws...)

# GNNGraph(g::AbstractGraph; kws...) = GNNGraph(adjacency_matrix(g, dir=:out); kws...)

function GNNGraph(g::AbstractGraph; kws...)
    s = LightGraphs.src.(LightGraphs.edges(g))
    t = LightGraphs.dst.(LightGraphs.edges(g))
    GNNGraph((s, t); num_nodes = LightGraphs.nv(g), kws...)
end

function GNNGraph(g::GNNGraph; ndata=g.ndata, edata=g.edata, gdata=g.gdata)

    ndata = normalize_graphdata(ndata, :x)
    edata = normalize_graphdata(edata, :e)
    gdata = normalize_graphdata(gdata, :u)
    
    GNNGraph(g.graph, 
            g.num_nodes, g.num_edges, g.num_graphs, 
            g.graph_indicator, 
            ndata, edata, gdata) 
end

function Base.show(io::IO, g::GNNGraph)
    println(io, "GNNGraph:
    num_nodes = $(g.num_nodes)
    num_edges = $(g.num_edges)
    num_graphs = $(g.num_graphs)")
    println(io, "    ndata:")
    for k in keys(g.ndata)
        println(io, "        $k => $(size(g.ndata[k]))")
    end
    println(io, "    edata:")
    for k in keys(g.edata)
        println(io, "        $k => $(size(g.edata[k]))")
    end
    println(io, "    gdata:")
    for k in keys(g.gdata)
        println(io, "        $k => $(size(g.gdata[k]))")
    end
end

"""
    edge_index(g::GNNGraph)

Return a tuple containing two vectors, respectively storing 
the source and target nodes for each edges in `g`.

```julia
s, t = edge_index(g)
```
"""
edge_index(g::GNNGraph{<:COO_T}) = g.graph[1:2]

edge_index(g::GNNGraph{<:ADJMAT_T}) = to_coo(g.graph)[1][1:2]

edge_weight(g::GNNGraph{<:COO_T}) = g.graph[3]

LightGraphs.edges(g::GNNGraph) = zip(edge_index(g)...)

LightGraphs.edgetype(g::GNNGraph) = Tuple{Int, Int}

function LightGraphs.has_edge(g::GNNGraph{<:COO_T}, i::Integer, j::Integer)
    s, t = edge_index(g)
    return any((s .== i) .& (t .== j))
end

LightGraphs.has_edge(g::GNNGraph{<:ADJMAT_T}, i::Integer, j::Integer) = g.graph[i,j] != 0

LightGraphs.nv(g::GNNGraph) = g.num_nodes
LightGraphs.ne(g::GNNGraph) = g.num_edges
LightGraphs.has_vertex(g::GNNGraph, i::Int) = 1 <= i <= g.num_nodes
LightGraphs.vertices(g::GNNGraph) = 1:g.num_nodes

function LightGraphs.outneighbors(g::GNNGraph{<:COO_T}, i::Integer)
    s, t = edge_index(g)
    return t[s .== i]
end

function LightGraphs.outneighbors(g::GNNGraph{<:ADJMAT_T}, i::Integer)
    A = g.graph
    return findall(!=(0), A[i,:])
end

function LightGraphs.inneighbors(g::GNNGraph{<:COO_T}, i::Integer)
    s, t = edge_index(g)
    return s[t .== i]
end

function LightGraphs.inneighbors(g::GNNGraph{<:ADJMAT_T}, i::Integer)
    A = g.graph
    return findall(!=(0), A[:,i])
end

LightGraphs.is_directed(::GNNGraph) = true
LightGraphs.is_directed(::Type{GNNGraph}) = true

function adjacency_list(g::GNNGraph; dir=:out)
    @assert dir ∈ [:out, :in]
    fneighs = dir == :out ? outneighbors : inneighbors
    return [fneighs(g, i) for i in 1:g.num_nodes]
end

function LightGraphs.adjacency_matrix(g::GNNGraph{<:COO_T}, T::DataType=Int; dir=:out)
    A, n, m = to_sparse(g.graph, T, num_nodes=g.num_nodes)
    @assert size(A) == (n, n)
    return dir == :out ? A : A'
end

function LightGraphs.adjacency_matrix(g::GNNGraph{<:ADJMAT_T}, T::DataType=eltype(g.graph); dir=:out)
    @assert dir ∈ [:in, :out]
    A = g.graph
    A = T != eltype(A) ? T.(A) : A
    return dir == :out ? A : A'
end

function LightGraphs.degree(g::GNNGraph{<:COO_T}, T=Int; dir=:out)
    s, t = edge_index(g)
    degs = fill!(similar(s, T, g.num_nodes), 0)
    o = fill!(similar(s, Int, g.num_edges), 1)
    if dir ∈ [:out, :both]
        NNlib.scatter!(+, degs, o, s)
    end
    if dir ∈ [:in, :both]
        NNlib.scatter!(+, degs, o, t)
    end
    return degs
end

function LightGraphs.degree(g::GNNGraph{<:ADJMAT_T}, T=Int; dir=:out)
    @assert dir ∈ (:in, :out)
    A = adjacency_matrix(g, T)
    return dir == :out ? vec(sum(A, dims=2)) : vec(sum(A, dims=1))
end

function LightGraphs.laplacian_matrix(g::GNNGraph, T::DataType=Int; dir::Symbol=:out)
    A = adjacency_matrix(g, T; dir=dir)
    D = Diagonal(vec(sum(A; dims=2)))
    return D - A
end

"""
    normalized_laplacian(g, T=Float32; add_self_loops=false, dir=:out)

Normalized Laplacian matrix of graph `g`.

# Arguments

- `g`: A `GNNGraph`.
- `T`: result element type.
- `add_self_loops`: add self-loops while calculating the matrix.
- `dir`: the edge directionality considered (:out, :in, :both).
"""
function normalized_laplacian(g::GNNGraph, T::DataType=Float32; 
                        add_self_loops::Bool=false, dir::Symbol=:out)
    Ã = normalized_adjacency(g, T; dir, add_self_loops)
    return I - Ã
end

function normalized_adjacency(g::GNNGraph, T::DataType=Float32; 
                        add_self_loops::Bool=false, dir::Symbol=:out)
    A = adjacency_matrix(g, T; dir=dir)
    if add_self_loops
        A = A + I
    end
    degs = vec(sum(A; dims=2))
    inv_sqrtD = Diagonal(inv.(sqrt.(degs)))
    return inv_sqrtD * A * inv_sqrtD
end

@doc raw"""
    scaled_laplacian(g, T=Float32; dir=:out)

Scaled Laplacian matrix of graph `g`,
defined as ``\hat{L} = \frac{2}{\lambda_{max}} L - I`` where ``L`` is the normalized Laplacian matrix.

# Arguments

- `g`: A `GNNGraph`.
- `T`: result element type.
- `dir`: the edge directionality considered (:out, :in, :both).
"""
function scaled_laplacian(g::GNNGraph, T::DataType=Float32; dir=:out)
    L = normalized_laplacian(g, T)
    @assert issymmetric(L) "scaled_laplacian only works with symmetric matrices"
    λmax = _eigmax(L)
    return  2 / λmax * L - I
end

# _eigmax(A) = eigmax(Symmetric(A)) # Doesn't work on sparse arrays
_eigmax(A) = KrylovKit.eigsolve(Symmetric(A), 1, :LR)[1][1] # also eigs(A, x0, nev, mode) available 

# Eigenvalues for cuarray don't seem to be well supported. 
# https://github.com/JuliaGPU/CUDA.jl/issues/154
# https://discourse.julialang.org/t/cuda-eigenvalues-of-a-sparse-matrix/46851/5

"""
    add_self_loops(g::GNNGraph)

Return a graph with the same features as `g`
but also adding edges connecting the nodes to themselves.

Nodes with already existing
self-loops will obtain a second self-loop.
"""
function add_self_loops(g::GNNGraph{<:COO_T})
    s, t = edge_index(g)
    @assert g.edata === (;)
    @assert edge_weight(g) === nothing
    n = g.num_nodes
    nodes = convert(typeof(s), [1:n;])
    s = [s; nodes]
    t = [t; nodes]

    GNNGraph((s, t, nothing), 
        g.num_nodes, length(s), g.num_graphs, 
        g.graph_indicator,
        g.ndata, g.edata, g.gdata)
end

function add_self_loops(g::GNNGraph{<:ADJMAT_T})
    A = g.graph
    @assert g.edata === (;)
    A = A + I
    num_edges =  g.num_edges + g.num_nodes
    GNNGraph(A, 
            g.num_nodes, num_edges, g.num_graphs, 
            g.graph_indicator,
            g.ndata, g.edata, g.gdata)
end

function remove_self_loops(g::GNNGraph{<:COO_T})
    s, t = edge_index(g)
    # TODO remove these constraints
    @assert g.edata === (;)
    @assert edge_weight(g) === nothing
    
    mask_old_loops = s .!= t
    s = s[mask_old_loops]
    t = t[mask_old_loops]

    GNNGraph((s, t, nothing), 
            g.num_nodes, length(s), g.num_graphs, 
            g.graph_indicator,
            g.ndata, g.edata, g.gdata)
end

function _catgraphs(g1::GNNGraph{<:COO_T}, g2::GNNGraph{<:COO_T})
    s1, t1 = edge_index(g1)
    s2, t2 = edge_index(g2)
    nv1, nv2 = g1.num_nodes, g2.num_nodes
    s = vcat(s1, nv1 .+ s2)
    t = vcat(t1, nv1 .+ t2)
    w = cat_features(edge_weight(g1), edge_weight(g2))

    ind1 = isnothing(g1.graph_indicator) ? fill!(similar(s1, Int, nv1), 1) : g1.graph_indicator 
    ind2 = isnothing(g2.graph_indicator) ? fill!(similar(s2, Int, nv2), 1) : g2.graph_indicator 
    graph_indicator = vcat(ind1, g1.num_graphs .+ ind2)
    
    GNNGraph((s, t, w),
            nv1 + nv2, g1.num_edges + g2.num_edges, g1.num_graphs + g2.num_graphs, 
            graph_indicator,
            cat_features(g1.ndata, g2.ndata),
            cat_features(g1.edata, g2.edata),
            cat_features(g1.gdata, g2.gdata))
end

### Cat public interfaces #############

"""
    blockdiag(xs::GNNGraph...)

Equivalent to [`Flux.batch`](@ref).
"""
function SparseArrays.blockdiag(g1::GNNGraph, gothers::GNNGraph...)
    g = g1
    for go in gothers
        g = _catgraphs(g, go)
    end
    return g
end

"""
    batch(xs::Vector{<:GNNGraph})

Batch together multiple `GNNGraph`s into a single one 
containing the total number of nodes and edges of the original graphs.

Equivalent to [`SparseArrays.blockdiag`](@ref).
"""
Flux.batch(xs::Vector{<:GNNGraph}) = blockdiag(xs...)

### LearnBase compatibility
LearnBase.nobs(g::GNNGraph) = g.num_graphs 
LearnBase.getobs(g::GNNGraph, i) = getgraph(g, i)[1]

# Flux's Dataloader compatibility. Related PR https://github.com/FluxML/Flux.jl/pull/1683
Flux.Data._nobs(g::GNNGraph) = g.num_graphs
Flux.Data._getobs(g::GNNGraph, i) = getgraph(g, i)[1]

#########################
Base.:(==)(g1::GNNGraph, g2::GNNGraph) = all(k -> getfield(g1,k)==getfield(g2,k), fieldnames(typeof(g1)))

"""
    getgraph(g::GNNGraph, i)

Return the getgraph of `g` induced by those nodes `v`
for which `g.graph_indicator[v] ∈ i`. In other words, it
extract the component graphs from a batched graph. 

It also returns a vector `nodes` mapping the new nodes to the old ones. 
The node `i` in the getgraph corresponds to the node `nodes[i]` in `g`.
"""
getgraph(g::GNNGraph, i::Int) = getgraph(g::GNNGraph{<:COO_T}, [i])

function getgraph(g::GNNGraph{<:COO_T}, i::AbstractVector{Int})
    if g.graph_indicator === nothing
        @assert i == [1]
        return g
    end

    node_mask = g.graph_indicator .∈ Ref(i)
    
    nodes = (1:g.num_nodes)[node_mask]
    nodemap = Dict(v => vnew for (vnew, v) in enumerate(nodes))

    graphmap = Dict(i => inew for (inew, i) in enumerate(i))
    graph_indicator = [graphmap[i] for i in g.graph_indicator[node_mask]]
    
    s, t, w = g.graph
    edge_mask = s .∈ Ref(nodes) 
    s = [nodemap[i] for i in s[edge_mask]]
    t = [nodemap[i] for i in t[edge_mask]]
    w = isnothing(w) ? nothing : w[edge_mask]
    
    ndata = getobs(g.ndata, node_mask)
    edata = getobs(g.edata, edge_mask)
    gdata = getobs(g.gdata, i)

    num_nodes = length(graph_indicator)
    num_edges = length(s)
    num_graphs = length(i)

    gnew = GNNGraph((s,t,w), 
                num_nodes, num_edges, num_graphs,
                graph_indicator,
                ndata, edata, gdata)
    return gnew, nodes
end

function node_features(g::GNNGraph)
    if isempty(g.ndata)
        return nothing
    elseif length(g.ndata) > 1
        @error "Multiple feature arrays, access directly through `g.ndata`"
    else
        return g.ndata[1]
    end
end

function edge_features(g::GNNGraph)
    if isempty(g.edata)
        return nothing
    elseif length(g.edata) > 1
        @error "Multiple feature arrays, access directly through `g.edata`"
    else
        return g.edata[1]
    end
end

function graph_features(g::GNNGraph)
    if isempty(g.gdata)
        return nothing
    elseif length(g.gdata) > 1
        @error "Multiple feature arrays, access directly through `g.gdata`"
    else
        return g.gdata[1]
    end
end


@non_differentiable normalized_laplacian(x...)
@non_differentiable normalized_adjacency(x...)
@non_differentiable scaled_laplacian(x...)
@non_differentiable adjacency_matrix(x...)
@non_differentiable adjacency_list(x...)
@non_differentiable degree(x...)
@non_differentiable add_self_loops(x...)     # TODO this is wrong, since g carries feature arrays, needs rrule
@non_differentiable remove_self_loops(x...)  # TODO this is wrong, since g carries feature arrays, needs rrule

# # delete when https://github.com/JuliaDiff/ChainRules.jl/pull/472 is merged
# function ChainRulesCore.rrule(::typeof(copy), x)
#     copy_pullback(ȳ) = (NoTangent(), ȳ)
#     return copy(x), copy_pullback
# end