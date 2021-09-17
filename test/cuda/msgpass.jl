@testset "cuda/msgpass" begin 
    in_channel = 10
    out_channel = 5
    N = 6
    T = Float32
    adj = [0 1 0 0 0 0
        1 0 0 1 1 1
        0 0 0 0 0 1
        0 1 0 0 1 0
        0 1 0 1 0 1
        0 1 1 0 1 0]

    struct NewCudaLayer{G} <: GNNLayer
        weight
    end
    NewCudaLayer{GRAPH_T}(m, n) = NewCudaLayer{GRAPH_T}(randn(T, m, n))
    Flux.@functor NewCudaLayer{GRAPH_T}

    (l::NewCudaLayer{GRAPH_T})(g, X) = GraphNeuralNetworks.propagate(l, g, +, X)[1]
    GraphNeuralNetworks.compute_message(n::NewCudaLayer{GRAPH_T}, x_i, x_j, e_ij) = n.weight * x_j
    GraphNeuralNetworks.update_node(::NewCudaLayer{GRAPH_T}, m, x) = m

    X = rand(T, in_channel, N) |> gpu
    g = GNNGraph(adj, ndata=X, graph_type=GRAPH_T)
    l = NewCudaLayer{GRAPH_T}(out_channel, in_channel) |> gpu

    g_ = l(g)
    @test size(node_features(g_)) == (out_channel, N)
end