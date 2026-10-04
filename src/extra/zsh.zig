const std = @import("std");

const Config = @import("../config/Config.zig");
const Action = @import("../cli.zig").ghostty.Action;

/// A zsh completions configuration that contains all the available commands
/// and options.
pub const completions = comptimeGenerateZshCompletions();

const equals_required = "=-:::";

fn comptimeGenerateZshCompletions() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeZshCompletions(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeZshCompletions(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

fn writeZshCompletions(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef ghostty
        \\
        \\_fonts () {
        \\  local font_list=$(ghostty +list-fonts | grep -Z '^[A-Z]')
        \\  local fonts=(${(f)font_list})
        \\  _describe -t fonts 'fonts' fonts
        \\}
        \\
        \\_themes() {
        \\  local theme_list=$(ghostty +list-themes | sed -E 's/^(.*) \(.*$/\1/')
        \\  local themes=(${(f)theme_list})
        \\  _describe -t themes 'themes' themes
        \\}
        \\
    );

    try writer.writeAll("_config() {\n");
    try writer.writeAll("  _arguments \\\n");
    try writer.writeAll("    \"--help\" \\\n");
    try writer.writeAll("    \"--version\" \\\n");
    for (@typeInfo(Config).@"struct".field_names) |field| {
        if (field[0] == '_') continue;
        try writer.writeAll("    \"--");
        try writer.writeAll(field);

        if (std.mem.startsWith(u8, field, "font-family")) {
            try writer.writeAll(equals_required);
            try writer.writeAll("_fonts");
        } else if (std.mem.eql(u8, "theme", field)) {
            try writer.writeAll(equals_required);
            try writer.writeAll("_themes");
        } else if (std.mem.eql(u8, "working-directory", field)) {
            try writer.writeAll(equals_required);
            try writer.writeAll("{_files -/}");
        } else if (@FieldType(Config, field) == Config.RepeatablePath) {
            try writer.writeAll(equals_required);
            try writer.writeAll("_files"); // todo check if this is needed
        } else {
            switch (@typeInfo(@FieldType(Config, field))) {
                .bool => {},
                .@"enum" => |info| {
                    try writer.writeAll(equals_required);
                    try writer.writeAll("(");
                    for (info.field_names, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f);
                    }
                    try writer.writeAll(")");
                },
                .@"struct" => |info| {
                    try writer.writeAll(equals_required);
                    if (!@hasDecl(@FieldType(Config, field), "parseCLI") and info.layout == .@"packed") {
                        try writer.writeAll("(");
                        for (info.field_names, 0..) |f, i| {
                            if (i > 0) try writer.writeAll(" ");
                            try writer.writeAll(f);
                            try writer.writeAll(" no-");
                            try writer.writeAll(f);
                        }
                        try writer.writeAll(")");
                    } else {
                        //resize-overlay-duration
                        //keybind
                        //window-padding-x ...-y
                        //link
                        //palette
                        //background
                        //foreground
                        //font-variation*
                        //font-feature
                        try writer.writeAll("( )");
                    }
                },
                else => {
                    try writer.writeAll(equals_required);
                    try writer.writeAll("( )");
                },
            }
        }

        try writer.writeAll("\" \\\n");
    }
    try writer.writeAll("\n}\n\n");

    try writer.writeAll(
        \\_ghostty() {
        \\  typeset -A opt_args
        \\  local context state line
        \\  local opt=('-e' '--help' '--version')
        \\
        \\  _arguments -C \
        \\    '1:actions:->actions' \
        \\    '*:: :->rest' \
        \\
        \\  if [[ "$line[1]" == "--help" || "$line[1]" == "--version" || "$line[1]" == "-e" ]]; then
        \\    return
        \\  fi
        \\
        \\  if [[ "$line[1]" == -* ]]; then
        \\    _config
        \\    return
        \\  fi
        \\
        \\  case "$state" in
        \\    (actions)
        \\      local actions; actions=(
        \\
    );

    {
        // how to get 'commands'
        var count: usize = 0;
        const padding = "        ";
        for (@typeInfo(Action).@"enum".field_names) |field| {
            try writer.writeAll(padding ++ "'+");
            try writer.writeAll(field);
            try writer.writeAll("'\n");
            count += 1;
        }
    }

    try writer.writeAll(
        \\      )
        \\      _describe '' opt
        \\      _describe -t action 'action' actions
        \\    ;;
        \\    (rest)
        \\      if [[ "$line[2]" == "--help" ]]; then
        \\        return
        \\      fi
        \\
        \\      local help=('--help')
        \\      _describe '' help
        \\
        \\      case $line[1] in
        \\
    );
    {
        const padding = "        ";
        for (@typeInfo(Action).@"enum".field_names) |field| {
            const options = @field(Action, field).options();
            // assumes options will never be created with only <_name> members
            if (@typeInfo(options).@"struct".field_names.len == 0) continue;

            try writer.writeAll(padding ++ "(+" ++ field ++ ")\n");
            try writer.writeAll(padding ++ "  _arguments \\\n");
            for (@typeInfo(options).@"struct".field_names) |opt| {
                if (opt[0] == '_') continue;

                try writer.writeAll(padding ++ "    '--");
                try writer.writeAll(opt);

                switch (@typeInfo(@FieldType(options, opt))) {
                    .bool => {},
                    .@"enum" => |info| {
                        try writer.writeAll(equals_required);
                        try writer.writeAll("(");
                        for (info.field_names, 0..) |f, i| {
                            if (i > 0) try writer.writeAll(" ");
                            try writer.writeAll(f);
                        }
                        try writer.writeAll(")");
                    },
                    .optional => |optional| {
                        try writer.writeAll(equals_required);
                        switch (@typeInfo(optional.child)) {
                            .@"enum" => |info| {
                                try writer.writeAll("(");
                                for (info.field_names, 0..) |f, i| {
                                    if (i > 0) try writer.writeAll(" ");
                                    try writer.writeAll(f);
                                }
                                try writer.writeAll(")");
                            },
                            else => {
                                if (std.mem.eql(u8, "config-file", opt)) {
                                    try writer.writeAll("_files");
                                } else try writer.writeAll("( )");
                            },
                        }
                    },
                    else => {
                        try writer.writeAll(equals_required);
                        if (std.mem.eql(u8, "config-file", opt)) {
                            try writer.writeAll("_files");
                        } else try writer.writeAll("( )");
                    },
                }

                try writer.writeAll("' \\\n");
            }
            try writer.writeAll(padding ++ ";;\n");
        }
    }
    try writer.writeAll(
        \\      esac
        \\    ;;
        \\  esac
        \\}
        \\
        \\_ghostty "$@"
        \\
    );
}
