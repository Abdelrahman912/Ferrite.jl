# abstract types and interfaces
abstract type AbstractIterator end
abstract type AbstractCellCache end

abstract type AbstractGPUCellCache <: AbstractCellCache end


function makecache(dh::AbstractGPUDofHandler, i::Int)
    # cache shall be generated by the dof handler on GPU. (i.e. no cell iterators on GPU)
    throw(ArgumentError("makecache should be implemented in the derived type"))
end

# concrete types
##### GPU #####
struct GPUCellCache{ DOFS <: AbstractVector{Int32},NN,NODES <: SVector{NN,Int32},X, COORDS<: SVector{X}} <: AbstractGPUCellCache
    # these are the basic fields that are required for the cache (at least from my point of view).
    # we don't want to make this a heavy object, because there will be stanbdalone instances of this object on the GPU.
    coords::COORDS
    dofs::DOFS
    cellid::Int32
    nodes::NODES
end


function makecache(dh::GPUDofHandler, i::Int32)
    # Note: here required fields are all extracted in one single functions,
    # although there are seperate functions to extract each field, because
    # On GPU, we want to minimize the number of memomry accesses.
    cellid = i
    grid = get_grid(dh)
    cell = getcells(grid,i);
    nodes = SVector(convert.(Int32,Ferrite.get_node_ids(cell))...)
    dofs = celldofs(dh, i)  # cannot be a SVectors, because the size is not known at compile time.


    # get the coordinates of the nodes of the cell.
    CT = get_coordinate_type(grid)
    N = nnodes(cell)
    x = MVector{N, CT}(undef) # local array to store the coordinates of the nodes of the cell.
    for i in eachindex(x)
        x[i] = get_node_coordinate(grid, nodes[i])
    end
    coords = SVector(x...)
    return GPUCellCache(coords, dofs, cellid, nodes)
end

# Accessor functions (TODO: Deprecate? We are so inconsistent with `getxx` vs `xx`...)
getnodes(cc::GPUCellCache) = cc.nodes
getcoordinates(cc::GPUCellCache) = cc.coords
celldofs(cc::GPUCellCache) = cc.dofs
cellid(cc::GPUCellCache) = cc.cellid
