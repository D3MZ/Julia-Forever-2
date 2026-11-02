using PrecompileTools: @compile_workload

@compile_workload begin
    terminal_compile_workload()
    # Compile startup signatures without executing configuration, terminal I/O or authentication.
    precompile(Tuple{typeof(terminal_app)})
    precompile(Tuple{typeof(JuliaForever2.main)})
    precompile(Tuple{typeof(Tachikoma.app),App})
end
