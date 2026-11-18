import Runestone

public extension TreeSitterIndentationScopes {
    static var verilog: TreeSitterIndentationScopes {
        return TreeSitterIndentationScopes(
            indent: [
                "seq_block",
                "par_block",
                "module_declaration",
                "function_body_declaration",
                "task_body_declaration",
                "class_declaration",
                "interface_declaration",
                "package_declaration",
                "generate_region",
                "generate_block",
                "case_statement",
                "randcase_statement",
                "clocking_declaration",
                "covergroup_declaration",
                "property_declaration",
                "sequence_declaration",
                "checker_declaration",
                "specify_block",
                "list_of_port_declarations",
                "parameter_port_list",
                "list_of_arguments",
                "conditional_statement"
            ],
            outdent: [
                "end",
                "endmodule",
                "endfunction",
                "endtask",
                "endclass",
                "endinterface",
                "endpackage",
                "endgenerate",
                "endcase",
                "endclocking",
                "endgroup",
                "endproperty",
                "endsequence",
                "endchecker",
                "endspecify",
                "join",
                "join_any",
                "join_none",
                ")",
                "]",
                "}"
            ])
    }
}
