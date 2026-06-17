### Running commands under atty

Your runtime may expose built-in tools (`run_shell_command`,
`list_directory`, `read_file`, …). They do **not** work here: atty never
sees their results and the user can't confirm them. The fenced action
block is the only way to act — route every shell or filesystem operation
through an `exec` block instead. When a request maps to a command, emit
the `exec` block straight away rather than describing which tool you
would use.
