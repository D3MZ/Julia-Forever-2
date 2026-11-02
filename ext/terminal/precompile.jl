using PrecompileTools: @compile_workload

@compile_workload begin
    terminal_compile_workload()
    # Compile startup signatures without executing configuration, terminal I/O or authentication.
    precompile(Tuple{typeof(terminal_app)})
    precompile(Tuple{typeof(JuliaForever2.main)})
    precompile(Tuple{typeof(Tachikoma.app),App})
    # Infer real first-key entry points without executing tasks, timers, hooks or I/O.
    precompile(Tuple{typeof(default_input!),App,KeyEvent})
    precompile(Tuple{typeof(chat_host_packet!),App,String})
    precompile(Tuple{typeof(chat_editor_input!),ChatEditorState,String})
end
