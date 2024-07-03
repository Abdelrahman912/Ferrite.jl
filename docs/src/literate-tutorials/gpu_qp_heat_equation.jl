using Ferrite, CUDA
using StaticArrays
using SparseArrays
using Adapt


left = Tensor{1,2,Float32}((0,-0)) # define the left bottom corner of the grid.
right = Tensor{1,2,Float32}((4.0,4.0)) # define the right top corner of the grid.


grid = generate_grid(Quadrilateral, (4, 4),left,right) 


colors = create_coloring(grid) .|> (x -> Int32.(x)) # convert to Int32 to reduce number of registers


ip = Lagrange{RefQuadrilateral, 1}() # define the interpolation function (i.e. Bilinear lagrange)


qr = QuadratureRule{RefQuadrilateral,Float32}(2) 


cellvalues = CellValues(Float32,qr, ip)


dh = DofHandler(grid)


add!(dh, :u, ip)

close!(dh);


# Standard assembly of the element.
function assemble_element_std!(Ke::Matrix, fe::Vector, cellvalues::CellValues)
    n_basefuncs = getnbasefunctions(cellvalues)

    # Loop over quadrature points
    for q_point in 1:getnquadpoints(cellvalues)
        # Get the quadrature weight
        dΩ = getdetJdV(cellvalues, q_point)
        # Loop over test shape functions
        for i in 1:n_basefuncs
            δu  = shape_value(cellvalues, q_point, i)
            ∇δu = shape_gradient(cellvalues, q_point, i)
            # Add contribution to fe
            fe[i] += δu * dΩ
            # Loop over trial shape functions
            for j in 1:n_basefuncs
                ∇u = shape_gradient(cellvalues, q_point, j)
                # Add contribution to Ke
                Ke[i, j] += (∇δu ⋅ ∇u) * dΩ
            end
        end
    end
    return Ke, fe
end


function create_buffers(cellvalues, dh)
    f = zeros(ndofs(dh))
    K = create_sparsity_pattern(dh)
    assembler = start_assemble(K, f)
    ## Local quantities
    n_basefuncs = getnbasefunctions(cellvalues)
    Ke = zeros(n_basefuncs, n_basefuncs)
    fe = zeros(n_basefuncs)
    return (;f, K, assembler, Ke, fe)
end


# Standard global assembly

function assemble_global!(cellvalues, dh::DofHandler,qp_iter::Val{QPiter}) where {QPiter}
    (;f, K, assembler, Ke, fe) = create_buffers(cellvalues,dh)
    # Loop over all cels
    for cell in CellIterator(dh)
        fill!(Ke, 0)
        fill!(fe, 0)
        if QPiter
            #reinit!(cellvalues, getcoordinates(cell))
            assemble_element_qpiter!(Ke, fe, cellvalues,getcoordinates(cell))
        else
            # Reinitialize cellvalues for this cell
            reinit!(cellvalues, cell)
            # Compute element contribution
            assemble_element_std!(Ke, fe, cellvalues)
        end
        # Assemble Ke and fe into K and f
        assemble!(assembler, celldofs(cell), Ke, fe)
    end
    return K, f
end


function assemble_element_gpu!(assembler,cv,dh,n_cells_colored, eles_colored)
    tx = threadIdx().x 
    bx = blockIdx().x
    bd = blockDim().x
    e_color = tx + (bx-Int32(1))*bd # element number per color
    e_color ≤ n_cells_colored || return nothing # e here is the current element index.
    n_basefuncs = getnbasefunctions(cv)
    e = eles_colored[e_color]
    cell_coords = getcoordinates(dh.grid, e)

    ke = MMatrix{4,4,Float32}(undef) # Note: using n_basefuncs instead of 4 will throw an error because this type of dynamisim is not supported in GPU.
    fill!(ke, 0.0f0)
    fe = MVector{4,Float32}(undef)
    fill!(fe, 0.0f0)
     # Loop over quadrature points
     for qv in Ferrite.QuadratureValuesIterator(cv,cell_coords)
        ## Get the quadrature weight
        dΩ = getdetJdV(qv)
        ## Loop over test shape functions
        for i in 1:n_basefuncs
            δu  = shape_value(qv, i)
            ∇δu = shape_gradient(qv, i)
            ## Add contribution to fe
            fe[i] += δu * dΩ
            ## Loop over trial shape functions
            for j in 1:n_basefuncs
                ∇u = shape_gradient(qv, j)
                ## Add contribution to Ke
                ke[i,j] += (∇δu ⋅ ∇u) * dΩ
            end
        end
    end

    ## Assemble Ke into Kgpu ##
    assemble!(assembler, celldofs(dh,e),SMatrix(ke),SVector(fe)) # when passin mutable objects, throws and error

    return nothing
end



function assemble_global_gpu_color(cellvalues,dh,colors)
    K = create_sparsity_pattern(dh,Float32)
    Kgpu = CUSPARSE.CuSparseMatrixCSC(K)
    fgpu = CUDA.zeros(ndofs(dh))
    assembler = start_assemble(Kgpu, fgpu)
    n_colors = length(colors)
    # set up kernel adaption 
    dh_gpu = Adapt.adapt_structure(CUDA.KernelAdaptor(), dh)
    assembler_gpu = Adapt.adapt_structure(CUDA.KernelAdaptor(), assembler)
    cellvalues_gpu = Adapt.adapt_structure(CUDA.KernelAdaptor(), cellvalues)
    for i in 1:n_colors
        kernel = @cuda launch=false assemble_element_gpu!(assembler_gpu,cellvalues_gpu,dh_gpu,Int32(length(colors[i])),cu(colors[i]))
        #@show CUDA.registers(kernel)
        config = launch_configuration(kernel.fun)
        threads = min(length(colors[i]), config.threads)
        blocks =  cld(length(colors[i]), threads)
        kernel(assembler_gpu,cellvalues,dh_gpu,Int32(length(colors[i])),cu(colors[i]);  threads, blocks)
    end
    return Kgpu,fgpu
end

function assemble_global_gpu_color_macro(cellvalues,dh,colors)
    K = create_sparsity_pattern(dh,Float32)
    Kgpu = CUSPARSE.CuSparseMatrixCSC(K)
    fgpu = CUDA.zeros(ndofs(dh))
    assembler = start_assemble(Kgpu, fgpu)

    # set up kernel adaption & launch the kernel
    @run_gpu(assemble_element_gpu!, assembler, cellvalues, dh, colors)
    return Kgpu,fgpu
end





stassy(cv,dh) = assemble_global!(cv,dh,Val(false))



# qpassy(cv,dh) = assemble_global!(cv,dh,Val(true))



Kgpu, fgpu =    assemble_global_gpu_color(cellvalues,dh,colors)
mKgpu, mfgpu =    assemble_global_gpu_color_macro(cellvalues,dh,colors)


norm(Kgpu)


#Kstd , Fstd = @btime stassy($cellvalues,$dh);
Kstd , Fstd =  stassy(cellvalues,dh);
norm(Kstd)

