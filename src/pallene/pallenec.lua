-- Copyright (c) 2022, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

-- PALLENEC SCRIPT
-- ===============
-- This is the main entry point for the pallenec compiler

local argparse = require "argparse"
local driver = require "pallene.driver"
local print_ir = require "pallene.print_ir"
local util = require "pallene.util"

local pallenec = {}

-- For compilation errors that don't happen inside a source file.
-- Inspired by gcc, eg. "gcc: fatal error: no input files".
local compiler_name = arg[0]

-- Command-line options
local opts
do
    local p = argparse("pallenec", "Pallene compiler")
    p:argument("source_file", "File to compile")

    -- What the compiler should output.
    p:mutex(
        p:flag("--emit-c",    "Generate a .c file instead of an executable"),
        p:flag("--emit-lua",  "Generate a .lua file instead of an executable"),
        p:flag("--emit-lua-preserve-columns",
          "Generate a .lua file instead of an executable with"
          .. "\nthe positions of tokens preserved (useful with"
          .. "\nLua diagnostics tool source mapping)"),
        p:flag("--compile-c", "Compile a .c file generated by --emit-c"),
        p:flag("--only-check","Check for syntax or type errors, without compiling"),
        p:flag("--print-ir",  "Show the intermediate representation for a program")
    )

    p:option("-O", "Optimization level")
        :args(1):convert(tonumber)
        :choices({"0", "1", "2", "3"})
        :default(2)

    p:option("-o --output", "Output file path")

    opts = p:parse()
end

local function compile(in_ext, out_ext)
    local ok, errs = driver.compile(compiler_name, opts.O, in_ext, out_ext, opts.source_file,
        opts.output)
    if not ok then util.abort(table.concat(errs, "\n")) end
end

local function compile_up_to(stop_after)
    local input, err = driver.load_input(opts.source_file)
    if err then util.abort(err) end

    local out, errs = driver.compile_internal(opts.source_file, input, stop_after, opts.O)
    if not out then util.abort(table.concat(errs, "\n")) end

    return out
end

local function do_check()
    compile_up_to("uninitialized")
end

local function do_print_ir()
    local module = compile_up_to("optimize")
    io.stdout:write(print_ir(module))
end

function pallenec.main()
    if     opts.emit_c      then compile("pln", "c")
    elseif opts.emit_lua    then compile("pln", "lua")
    elseif opts.emit_lua_preserve_columns then compile("pln", "lua_pc")
    elseif opts.compile_c   then compile("c" ,  "so")
    elseif opts.only_check  then do_check()
    elseif opts.print_ir    then do_print_ir()
    else --[[default]]           compile("pln", "so")
    end
end

return pallenec
