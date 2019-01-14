local parser = {}

local re = require "relabel"
local inspect = require "inspect"

local ast = require "pallene.ast"
local lexer = require "pallene.lexer"
local location = require "pallene.location"
local syntax_errors = require "pallene.syntax_errors"

-- File name of the file that is currently being parsed.
-- Since this is a global the parser is not reentrant but we couldn't think of
-- a better way yet. (If only lpeg.re had Carg...)
local THIS_FILENAME = nil

--
-- Functions used by the PEG grammar
--

local defs = {}

for tokname, tokpat in pairs(lexer) do
    defs[tokname] = tokpat
end

for typename, conss in pairs(ast) do
    if type(conss) == "table" then
        for tag, cons in pairs(conss) do
            local name = typename .. tag
            assert(not defs[name])
            defs[name] = cons
        end
    end
end

function defs.get_loc(s, pos)
    return true, location.from_pos(THIS_FILENAME, s, pos)
end

function defs.totrue()
    return true
end

function defs.tofalse()
    return false
end

function defs.rettypeopt(_pos, x)
    if not x then
        return { }
    else
        return x
    end
end

function defs.opt(x)
    if x == "" then
        return false
    else
        return x
    end
end
function defs.boolopt(x)
    return x ~= ""
end

function defs.nil_exp(pos--[[, s ]])
    -- We can't call ast.Exp.Nil directly in the parser because we
    -- need to drop the string capture that comes in the second argument.
    return ast.Exp.Nil(pos)
end

function defs.number_exp(pos, n)
    if math.type(n) == "integer" then
        return ast.Exp.Integer(pos, n)
    elseif math.type(n) == "float" then
        return ast.Exp.Float(pos, n)
    else
        error("impossible")
    end
end

function defs.name_exp(pos, name)
    return ast.Exp.Var(pos, ast.Var.Name(pos, name))
end

function defs.ifstat(pos, exp, block, elseifs, elseopt)
    local else_ = elseopt or ast.Stat.Block(pos, {})

    for i = #elseifs, 1, -1 do
        local e = elseifs[i]
        else_ = ast.Stat.If(e.pos, e.exp, e.block, else_)
    end

    return ast.Stat.If(pos, exp, block, else_)
end

function defs.elseif_(pos, exp, block)
    return { pos=pos, exp=exp, block=block }
end

function defs.fold_binop_left(pos, matches)
    local lhs = matches[1]
    for i = 2, #matches, 2 do
        local op  = matches[i]
        local rhs = matches[i+1]
        lhs = ast.Exp.Binop(pos, lhs, op, rhs)
    end
    return lhs
end

-- Should this go on a separate constant propagation pass?
function defs.binop_concat(pos, lhs, op, rhs)
    if op then
        if rhs._tag == ast.Exp.Concat then
            table.insert(rhs.exps, 1, lhs)
            return rhs
        elseif (lhs._tag == ast.Exp.String or
            lhs._tag == ast.Exp.Integer or
            lhs._tag == ast.Exp.Float) and
            (rhs._tag == ast.Exp.String or
            rhs._tag == ast.Exp.Integer or
            rhs._tag == ast.Exp.Float) then
            return ast.Exp.String(pos, lhs.value .. rhs.value)
        else
            return ast.Exp.Concat(pos, { lhs, rhs })
        end
    else
        return lhs
    end
end

function defs.binop_right(pos, lhs, op, rhs)
    if op then
        return ast.Exp.Binop(pos, lhs, op, rhs)
    else
        return lhs
    end
end

function defs.fold_unops(pos, unops, exp)
    for i = #unops, 1, -1 do
        local op = unops[i]
        exp = ast.Exp.Unop(pos, op, exp)
    end
    return exp
end

-- We represent the suffix of an expression by a function that receives the
-- base expression and returns a full expression including the suffix.

function defs.suffix_funccall(pos, args)
    return function(exp)
        return ast.Exp.CallFunc(pos, exp,  args)
    end
end

function defs.suffix_methodcall(pos, name, args)
    return function(exp)
        return ast.Exp.CallMethod(pos, exp, name, args)
    end
end

function defs.suffix_bracket(pos, index)
    return function(exp)
        return ast.Exp.Var(pos, ast.Var.Bracket(pos, exp, index))
    end
end

function defs.suffix_dot(pos, name)
    return function(exp)
        return ast.Exp.Var(pos, ast.Var.Dot(pos, exp, name))
    end
end

function defs.fold_suffixes(exp, suffixes)
    for i = 1, #suffixes do
        local suf = suffixes[i]
        exp = suf(exp)
    end
    return exp
end

function defs.exp2var(exp)
    return exp.var
end

function defs.exp_is_var(_, pos, exp)
    if exp._tag == ast.Exp.Var then
        return pos, exp
    else
        return false
    end
end

function defs.exp_is_call(_, pos, exp)
    if exp._tag == ast.Exp.CallFunc or
       exp._tag == ast.Exp.CallMethod then
        return pos, exp
    else
        return false
    end
end

local grammar = re.compile([[

    program         <-  SKIP*
                        {| ( toplevelfunc
                           / toplevelvar
                           / toplevelrecord
                           / import )* |} !.

    toplevelfunc    <- (P  localopt FUNCTION NAME^NameFunc
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> ToplevelFunc

    toplevelvar     <- (P  LOCAL decl ASSIGN^AssignVar
                           !IMPORT exp^ExpVarDec)                -> ToplevelVar

    toplevelrecord  <- (P  RECORD NAME^NameRecord recordfields
                           END^EndRecord)                        -> ToplevelRecord

    localopt        <- (LOCAL)?                                  -> boolopt

    import          <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                           IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                          STRINGLIT^StringImport))               -> ToplevelImport

    rettypeopt      <- (P  (COLON rettype^TypeFunc)?)            -> rettypeopt

    paramlist       <- {| (param (COMMA param^DeclParList)*)? |} -- produces {Decl}

    param           <- (P  NAME COLON^ParamSemicolon
                           type^TypeDecl)                        -> DeclDecl

    decl            <- (P  NAME (COLON type^TypeDecl)? -> opt)   -> DeclDecl

    simpletype      <- (P  NIL)                                  -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  VALUE)                                -> TypeValue
                     / (P  NAME)                                 -> TypeName
                     / (P  LCURLY type^TypeType
                           RCURLY^RCurlyType)                    -> TypeArray

    typelist        <- ( LPAREN
                         {| (type (COMMA type^TypelistType)*)? |}
                         RPAREN^RParenTypelist )                 -- produces {Type}

    rettype         <- {| (P  typelist RARROW
                            rettype^TypeReturnTypes)             -> TypeFunction |}
                     / {| (P  {| simpletype |} RARROW
                             rettype^TypeReturnTypes)            -> TypeFunction |}
                     / typelist
                     / {| simpletype |}

    type            <- (P  typelist RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / (P  {| simpletype |} RARROW
                           rettype^TypeReturnTypes)              -> TypeFunction
                     / simpletype

    recordfields    <- {| recordfield* |}                        -- produces {Decl}

    recordfield     <- (P  NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> DeclDecl

    block           <- (P  {| statement* returnstat? |})         -> StatBlock

    statement       <- (SEMICOLON)                               -- ignore
                     / (DO block END^EndBlock)                   -- produces StatBlock
                     / (P  WHILE exp^ExpWhile DO^DoWhile
                                 block END^EndWhile)             -> StatWhile
                     / (P  REPEAT block UNTIL^UntilRepeat
                                      exp^ExpRepeat)             -> StatRepeat
                     / (P  IF exp^ExpIf THEN^ThenIf block
                           elseifstats elseopt END^EndIf)        -> ifstat
                     / (P  FOR decl^DeclFor
                           ASSIGN^AssignFor exp^Exp1For
                           COMMA^CommaFor exp^Exp2For
                           (COMMA exp^Exp3For)?                  -> opt
                           DO^DoFor block END^EndFor)            -> StatFor
                     / (P  LOCAL decl^DeclLocal ASSIGN^AssignLocal
                                 exp^ExpLocal)                   -> StatDecl
                     / (P  var ASSIGN^AssignAssign
                               exp^ExpAssign)                    -> StatAssign
                     / &(exp ASSIGN) %{AssignNotToVar}
                     / (P  (suffixedexp => exp_is_call))         -> StatCall
                     / &exp %{ExpStat}

    elseifstats     <- {| elseifstat* |}                         -- produces {elseif}

    elseifstat      <- (P  ELSEIF exp^ExpElseIf
                           THEN^ThenElseIf block)                -> elseif_

    elseopt         <- (ELSE block)?                             -> opt

    returnstat      <- (P  RETURN {| exp? |} SEMICOLON?)         -> StatReturn

    op1             <- ( OR -> 'or' )
    op2             <- ( AND -> 'and' )
    op3             <- ( EQ -> '==' / NE -> '~=' / LT -> '<' /
                         GT -> '>'  / LE -> '<=' / GE -> '>=' )
    op4             <- ( BOR -> '|' )
    op5             <- ( BXOR -> '~' )
    op6             <- ( BAND -> '&' )
    op7             <- ( SHL -> '<<' / SHR -> '>>' )
    op8             <- ( CONCAT -> '..' )
    op9             <- ( ADD -> '+' / SUB -> '-' )
    op10            <- ( MUL -> '*' / MOD -> '%%' / DIV -> '/' / IDIV -> '//' )
    unop            <- ( NOT -> 'not' / LEN -> '#' / NEG -> '-' / BNEG -> '~' )
    op12            <- ( POW -> '^' )

    exp             <- e1
    e1              <- (P  {| e2  (op1  e2^OpExp)* |})           -> fold_binop_left
    e2              <- (P  {| e3  (op2  e3^OpExp)* |})           -> fold_binop_left
    e3              <- (P  {| e4  (op3  e4^OpExp)* |})           -> fold_binop_left
    e4              <- (P  {| e5  (op4  e5^OpExp)* |})           -> fold_binop_left
    e5              <- (P  {| e6  (op5  e6^OpExp)* |})           -> fold_binop_left
    e6              <- (P  {| e7  (op6  e7^OpExp)* |})           -> fold_binop_left
    e7              <- (P  {| e8  (op7  e8^OpExp)* |})           -> fold_binop_left
    e8              <- (P     e9  (op8  e8^OpExp)?)              -> binop_concat
    e9              <- (P  {| e10 (op9  e10^OpExp)* |})          -> fold_binop_left
    e10             <- (P  {| e11 (op10 e11^OpExp)* |})          -> fold_binop_left
    e11             <- (P  {| unop* |}  e12)                     -> fold_unops
    e12             <- (P  castexp (op12 e11^OpExp)?)            -> binop_right

    suffixedexp     <- (prefixexp {| expsuffix+ |})              -> fold_suffixes

    expsuffix       <- (P  funcargs)                             -> suffix_funccall
                     / (P  COLON NAME^NameColonExpSuf
                                 funcargs^FuncArgsExpSuf)        -> suffix_methodcall
                     / (P  LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> suffix_bracket
                     / (P  DOT NAME^NameDotExpSuf)               -> suffix_dot

    prefixexp       <- (P  NAME)                                 -> name_exp
                     / (LPAREN exp^ExpSimpleExp
                               RPAREN^RParSimpleExp)             -- produces Exp


    castexp         <- (P  simpleexp AS type^CastMissingType)    -> ExpCast
                     / simpleexp                                 -- produces Exp

    simpleexp       <- (P  NIL)                                  -> nil_exp
                     / (P  FALSE -> tofalse)                     -> ExpBool
                     / (P  TRUE -> totrue)                       -> ExpBool
                     / (P  NUMBER)                               -> number_exp
                     / (P  STRINGLIT)                            -> ExpString
                     / initlist                                  -- produces Exp
                     / suffixedexp                               -- produces Exp
                     / prefixexp                                 -- produces Exp

    var             <- (suffixedexp => exp_is_var)               -> exp2var
                     / (P  NAME !expsuffix)                      -> name_exp -> exp2var

    funcargs        <- (LPAREN explist RPAREN^RParFuncArgs)      -- produces {Exp}
                     / {| initlist |}                            -- produces {Exp}
                     / {| (P  STRINGLIT) -> ExpString |}         -- produces {Exp}

    explist         <- {| (exp (COMMA exp^ExpExpList)*)? |}      -- produces {Exp}

    initlist        <- (P  LCURLY {| fieldlist? |}
                                  RCURLY^RCurlyInitList)         -> ExpInitlist

    fieldlist       <- (field
                        (fieldsep
                         (field /
                          !RCURLY %{ExpFieldList}))*
                        fieldsep?)                          -- produces Field...

    field           <- (P  (NAME ASSIGN)? -> opt exp)       -> FieldField

    fieldsep        <- SEMICOLON / COMMA

    --
    -- Get current position
    --

    P <- {} => get_loc

    -- Create new rules for all our tokens, for the whitespace-skipping magic
    -- Currently done by hand but this is something that parser-gen should be
    -- able to do for us.

    SKIP            <- (%SPACE / %COMMENT)

    AND             <- %AND SKIP*
    BREAK           <- %BREAK SKIP*
    DO              <- %DO SKIP*
    ELSE            <- %ELSE SKIP*
    ELSEIF          <- %ELSEIF SKIP*
    END             <- %END SKIP*
    FALSE           <- %FALSE SKIP*
    FOR             <- %FOR SKIP*
    FUNCTION        <- %FUNCTION SKIP*
    GOTO            <- %GOTO SKIP*
    IF              <- %IF SKIP*
    IN              <- %IN SKIP*
    LOCAL           <- %LOCAL SKIP*
    NIL             <- %NIL SKIP*
    NOT             <- %NOT SKIP*
    OR              <- %OR SKIP*
    RECORD          <- %RECORD SKIP*
    REPEAT          <- %REPEAT SKIP*
    RETURN          <- %RETURN SKIP*
    THEN            <- %THEN SKIP*
    TRUE            <- %TRUE SKIP*
    UNTIL           <- %UNTIL SKIP*
    WHILE           <- %WHILE SKIP*
    IMPORT          <- %IMPORT SKIP*
    AS              <- %AS SKIP*

    BOOLEAN         <- %BOOLEAN SKIP*
    INTEGER         <- %INTEGER SKIP*
    FLOAT           <- %FLOAT SKIP*
    STRING          <- %STRING SKIP*
    VALUE           <- %VALUE SKIP*

    ADD             <- %ADD SKIP*
    SUB             <- %SUB SKIP*
    MUL             <- %MUL SKIP*
    MOD             <- %MOD SKIP*
    DIV             <- %DIV SKIP*
    IDIV            <- %IDIV SKIP*
    POW             <- %POW SKIP*
    LEN             <- %LEN SKIP*
    BAND            <- %BAND SKIP*
    BXOR            <- %BXOR SKIP*
    BOR             <- %BOR SKIP*
    SHL             <- %SHL SKIP*
    SHR             <- %SHR SKIP*
    CONCAT          <- %CONCAT SKIP*
    EQ              <- %EQ SKIP*
    LT              <- %LT SKIP*
    GT              <- %GT SKIP*
    NE              <- %NE SKIP*
    LE              <- %LE SKIP*
    GE              <- %GE SKIP*
    ASSIGN          <- %ASSIGN SKIP*
    LPAREN          <- %LPAREN SKIP*
    RPAREN          <- %RPAREN SKIP*
    LBRACKET        <- %LBRACKET SKIP*
    RBRACKET        <- %RBRACKET SKIP*
    LCURLY          <- %LCURLY SKIP*
    RCURLY          <- %RCURLY SKIP*
    SEMICOLON       <- %SEMICOLON SKIP*
    COMMA           <- %COMMA SKIP*
    DOT             <- %DOT SKIP*
    DOTS            <- %DOTS SKIP*
    DBLCOLON        <- %DBLCOLON SKIP*
    COLON           <- %COLON SKIP*
    RARROW          <- %RARROW SKIP*

    NUMBER          <- %NUMBER SKIP*
    STRINGLIT       <- %STRINGLIT SKIP*
    NAME            <- %NAME SKIP*

    -- Synonyms

    NEG             <- SUB
    BNEG            <- BXOR

]], defs)

local function parser_error(loc, label)
    local errmsg = syntax_errors.errors[label]
    return location.format_error(loc, "syntax error: %s", errmsg)
end

function parser.parse(filename, input)
    -- Abort if someone calls this non-reentrant parser recursively
    assert(type(filename) == "string")
    assert(THIS_FILENAME == nil)

    THIS_FILENAME = filename
    local prog_ast, err, errpos = grammar:match(input)
    THIS_FILENAME = nil

    local errors = {}
    if not prog_ast then
        local loc = location.from_pos(filename, input, errpos)
        table.insert(errors, parser_error(loc, err))
    end
    return prog_ast, errors
end

function parser.pretty_print_ast(prog_ast)
    return inspect(prog_ast, {
        process = function(item, path)
            if path[#path] ~= inspect.METATABLE then
                return item
            end
        end
    })
end

return parser