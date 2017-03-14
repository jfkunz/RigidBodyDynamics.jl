module Graphs

using Compat

export
    DirectedGraph,
    SpanningTree,
    Edge,
    Vertex,
    vertex_index,
    edge_index,
    vertex_type,
    edge_type,
    vertices,
    edges,
    source,
    target,
    out_edges,
    in_edges,
    num_vertices,
    num_edges,
    add_vertex!,
    add_edge!,
    remove_vertex!,
    remove_edge!,
    rewire!,
    root,
    edge_to_parent,
    edges_to_children,
    tree_index,
    data,
    path

# Vertex interface
vertex_index(::Any) = error("Vertex types must implement this method")
vertex_index!(::Any, index::Int64) = error("Vertex types must implement this method")

# Edge interface
edge_index(::Any) = error("Edge types must implement this method")
edge_index!(::Any, index::Int64) = error("Edge types must implement this method")
flip_direction!(::Any) = nothing # optional

# Vertex and Edge types; useful for wrapping an existing type with the edge interface.
# Note that DirectedGraph does not require using these types; just implement the edge interface.
for typename in (:Edge, :Vertex)
    getid = Symbol(lowercase(string(typename)) * "_index")
    setid = Symbol(lowercase(string(typename)) * "_index!")
    @eval begin
        type $typename{T}
            data::T
            id::Int64

            $typename(data::T) = new(data, -1)
        end
        $typename{T}(data::T) = $typename{T}(data)
        data(x::$typename) = x.data
        $getid(x::$typename) = x.id
        $setid(x::$typename, index::Int64) = (x.id = index)
    end
end

@compat abstract type AbstractGraph{V, E} end
vertex_type{V, E}(::Type{AbstractGraph{V, E}}) = V
edge_type{V, E}(::Type{AbstractGraph{V, E}}) = E
num_vertices(g::AbstractGraph) = length(vertices(g))
num_edges(g::AbstractGraph) = length(edges(g))
out_neighbors{V, E}(vertex::V, g::AbstractGraph{V, E}) = (target(e, g) for e in out_edges(vertex, g))
in_neighbors{V, E}(vertex::V, g::AbstractGraph{V, E}) = (source(e, g) for e in in_edges(vertex, g))


type DirectedGraph{V, E} <: AbstractGraph{V, E}
    vertices::Vector{V}
    edges::Vector{E}
    sources::Vector{V}
    targets::Vector{V}
    inedges::Vector{Set{E}}
    outedges::Vector{Set{E}}

    DirectedGraph() = new(V[], E[], V[], V[], Set{E}[], Set{E}[])
end

# AbstractGraph interface
vertices(g::DirectedGraph) = g.vertices
edges(g::DirectedGraph) = g.edges
source{V, E}(edge::E, g::DirectedGraph{V, E}) = g.sources[edge_index(edge)]
target{V, E}(edge::E, g::DirectedGraph{V, E}) = g.targets[edge_index(edge)]
in_edges{V, E}(vertex::V, g::DirectedGraph{V, E}) = g.inedges[vertex_index(vertex)]
out_edges{V, E}(vertex::V, g::DirectedGraph{V, E}) = g.outedges[vertex_index(vertex)]

Base.show{V, E}(io::IO, ::DirectedGraph{V, E}) = print(io, "DirectedGraph{$V, $E}(…)")

function add_vertex!{V, E}(g::DirectedGraph{V, E}, vertex::V)
    @assert vertex ∉ vertices(g)

    vertex_index!(vertex, num_vertices(g) + 1)
    push!(g.vertices, vertex)
    push!(g.outedges, Set{E}())
    push!(g.inedges, Set{E}())
    g
end

function add_edge!{V, E}(g::DirectedGraph{V, E}, source::V, target::V, edge::E)
    @assert edge ∉ edges(g)
    source ∈ vertices(g) || add_vertex!(g, source)
    target ∈ vertices(g) || add_vertex!(g, target)

    edge_index!(edge, num_edges(g) + 1)
    push!(g.edges, edge)
    push!(g.sources, source)
    push!(g.targets, target)
    push!(out_edges(source, g), edge)
    push!(in_edges(target, g), edge)
    g
end

function remove_vertex!{V, E}(g::DirectedGraph{V, E}, vertex::V)
    disconnected = isempty(in_edges(vertex, g)) && isempty(out_edges(vertex, g))
    if !disconnected
        @show in_edges(vertex, g)
        @show out_edges(vertex, g)
    end
    disconnected || error("Vertex must be disconnected from the rest of the graph before it can be removed.")
    index = vertex_index(vertex)
    deleteat!(g.vertices, index)
    deleteat!(g.inedges, index)
    deleteat!(g.outedges, index)
    for i = index : num_vertices(g)
        vertex_index!(g.vertices[i], i)
    end
    vertex_index!(vertex, -1)
    g
end

function remove_edge!{V, E}(g::DirectedGraph{V, E}, edge::E)
    delete!(in_edges(target(edge, g), g), edge)
    delete!(out_edges(source(edge, g), g), edge)
    index = edge_index(edge)
    deleteat!(g.edges, index)
    deleteat!(g.sources, index)
    deleteat!(g.targets, index)
    for i = index : num_edges(g)
        edge_index!(g.edges[i], i)
    end
    edge_index!(edge, -1)
    g
end

function rewire!{V, E}(g::DirectedGraph{V, E}, edge::E, newsource::V, newtarget::V)
    oldsource = source(edge, g)
    oldtarget = target(edge, g)

    g.sources[edge_index(edge)] = newsource
    g.targets[edge_index(edge)] = newtarget

    delete!(out_edges(oldsource, g), edge)
    delete!(in_edges(oldtarget, g), edge)

    push!(out_edges(newsource, g), edge)
    push!(in_edges(newtarget, g), edge)

    g
end

function flip_direction!{V, E}(edge::E, g::DirectedGraph{V, E})
    flip_direction!(edge)
    rewire!(g, edge, target(edge, g), source(edge, g))
end

type SpanningTree{V, E} <: AbstractGraph{V, E}
    graph::DirectedGraph{V, E}
    edges::Vector{E}
    inedges::Vector{E}
    outedges::Vector{Set{E}}
    edge_tree_indices::Vector{Int64} # mapping from edge_index(edge) to index into edges(tree)
end

# AbstractGraph interface
vertices(tree::SpanningTree) = vertices(tree.graph)
edges(tree::SpanningTree) = tree.edges
source{V, E}(edge::E, tree::SpanningTree{V, E}) = source(edge, tree.graph) # note: doesn't check that edge is in spanning tree!
target{V, E}(edge::E, tree::SpanningTree{V, E}) = target(edge, tree.graph) # note: doesn't check that edge is in spanning tree!
in_edges{V, E}(vertex::V, tree::SpanningTree{V, E}) = (tree.inedges[vertex_index(vertex)],)
out_edges{V, E}(vertex::V, tree::SpanningTree{V, E}) = tree.outedges[vertex_index(vertex)]

root(tree::SpanningTree) = source(first(edges(tree)), tree)
edge_to_parent{V, E}(vertex::V, tree::SpanningTree{V, E}) = tree.inedges[vertex_index(vertex)]
edges_to_children{V, E}(vertex::V, tree::SpanningTree{V, E}) = out_edges(vertex, tree)
tree_index{V, E}(edge::E, tree::SpanningTree{V, E}) = tree.edge_tree_indices[edge_index(edge)]
tree_index{V, E}(vertex::V, tree::SpanningTree{V, E}) = vertex == root(tree) ? 1 : tree_index(edge_to_parent(vertex, tree), tree) + 1

function SpanningTree{V, E}(g::DirectedGraph{V, E}, edges::AbstractVector{E})
    n = num_vertices(g)
    length(edges) == n - 1 || error("Expected n - 1 edges.")
    inedges = Vector{E}(n)
    outedges = [Set{E}() for i = 1 : n]
    edge_tree_indices = Int64[]
    treevertices = V[]
    for (i, edge) in enumerate(edges)
        parent = source(edge, g)
        child = target(edge, g)
        isempty(treevertices) && push!(treevertices, parent)
        @assert parent ∈ treevertices
        inedges[vertex_index(child)] = edge
        push!(outedges[vertex_index(parent)], edge)
        push!(treevertices, child)
        resize!(edge_tree_indices, max(edge_index(edge), length(edge_tree_indices)))
        edge_tree_indices[edge_index(edge)] = i
    end
    SpanningTree(g, edges, inedges, outedges, edge_tree_indices)
end

function SpanningTree{V, E}(g::DirectedGraph{V, E}, root::V, next_edge = (graph, frontier) -> first(frontier))
    treevertices = [root]
    edges = E[]
    frontier = E[]
    append!(frontier, out_edges(root, g))
    while !isempty(frontier)
        # select a new edge
        e = next_edge(g, frontier)
        parent = source(e, g)
        child = target(e, g)

        # add edge to tree
        push!(edges, e)

        # update the frontier
        push!(treevertices, child)
        filter!(x -> x ∉ in_edges(child, g), frontier)
        append!(frontier, x for x in out_edges(child, g) if target(x, g) ∉ treevertices)
    end
    SpanningTree(g, edges)
end

# adds an edge and vertex to both the tree and the underlying graph
function add_edge!{V, E}(tree::SpanningTree{V, E}, source::V, target::V, edge::E)
    @assert target ∉ vertices(tree)
    add_edge!(tree.graph, source, target, edge)
    push!(tree.edges, edge)
    push!(tree.inedges, edge)
    push!(tree.outedges, Set{E}())
    push!(out_edges(source, tree), edge)
    resize!(tree.edge_tree_indices, max(edge_index(edge), length(tree.edge_tree_indices)))
    tree.edge_tree_indices[edge_index(edge)] = num_edges(tree)
    tree
end

function Base.show(io::IO, tree::SpanningTree, vertex = root(tree), level::Int64 = 0)
    for i = 1 : level print(io, "  ") end
    print(io, "Vertex: ")
    showcompact(io, vertex)
    if vertex == root(tree)
        print(io, " (root)")
    else
        print(io, ", ")
        print(io, "Edge: ")
        showcompact(io, edge_to_parent(vertex, tree))
    end
    for edge in edges_to_children(vertex, tree)
        print(io, "\n")
        child = target(edge, tree)
        show(io, tree, child, level + 1)
    end
end

function lowest_common_ancestor{V, E}(v1::V, v2::V, tree::SpanningTree{V, E})
    while v1 != v2
        if tree_index(v1, tree) > tree_index(v2, tree)
            v1 = source(edge_to_parent(v1, tree), tree)
        else
            v2 = source(edge_to_parent(v1, tree), tree)
        end
    end
    v1
end


# Path
immutable TreePath{E}
    source_to_lca::Vector{E}
    target_to_lca::Vector{E}
end

function Base.show(io::IO, path::TreePath)
    for edge in path.source_to_lca
        print(io, "↑ ")
        showcompact(io, edge)
        println(io)
    end
    for i = length(path.target_to_lca) : -1 : 1
        edge = path.target_to_lca[i]
        print(io, "↓ ")
        showcompact(io, edge)
        println(io)
    end
end

function path{V, E}(src::V, target::V, tree::SpanningTree{V, E})
    source_to_lca = E[]
    target_to_lca = E[]
    while src != target
        if tree_index(src, tree) > tree_index(target, tree)
            edge = edge_to_parent(src, tree)
            push!(source_to_lca, edge)
            src = source(edge, tree)
        else
            edge = edge_to_parent(target, tree)
            push!(target_to_lca, edge)
            target = source(edge, tree)
        end
    end
    TreePath(source_to_lca, target_to_lca)
end

end # module
