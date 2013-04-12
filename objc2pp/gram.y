/* ObjC-2.0 scanner - based on http://www.lysator.liu.se/c/ANSI-C-grammar-y.html */
/* part of objc2pp - an obj-c 2 preprocessor */

/*
 * FIXME:
 *
 * - accept *any* valid keyword as selector components (and not only non-keywords): + (void) for:x in:y default:z;
 * - correctly handle typedefs for list of names: typedef int t1, t2, t3;
 * - handle nesting of type specifiers, i.e. typedef int (*intfn)(int arg)
 * - handle global/local name scope
 * - handle name spaces for structs and enums
 * - handle @implementation, @interface, @protocol add the object to the (global) symbol table
 * - get notion of 'current class', 'current method' etc.
 * - collect @property entries so that @synthesisze can expand them
 * - add all these Obj-C 2.0 expansions
 *
 * - use the new multi-child approach for nodes
 * - just parse Obj-C 2.x
 * - don't mix with simplification and translation!!! I.e. it must be possible to reconstruct (pretty print) the source code (except for white-space)
 *
 */
 
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "node.h"
	
	int scope;		// scope list
	int rootnode;	// root node of the whole tree
	
	int declaratorName;	// current declarator IDENTIFIER object
	int currentDeclarationSpecifier;	// current storage class and base type (e.g. static int)

	int structNames;	// struct namespace (dictionary)
	/* is there a separate namespace for unions? */
	int enumNames;		// enum namespace (dictionary)
	int classNames;		// Class namespace (dictionary)
	int protocolNames;	// @protocol namespace (dictionary)

%}

%token SIZEOF PTR_OP INC_OP DEC_OP LEFT_OP RIGHT_OP LE_OP GE_OP EQ_OP NE_OP
%token AND_OP OR_OP MUL_ASSIGN DIV_ASSIGN MOD_ASSIGN ADD_ASSIGN
%token SUB_ASSIGN LEFT_ASSIGN RIGHT_ASSIGN AND_ASSIGN
%token XOR_ASSIGN OR_ASSIGN 

%token TYPEDEF EXTERN STATIC AUTO REGISTER
%token CHAR SHORT INT LONG SIGNED UNSIGNED FLOAT DOUBLE CONST VOLATILE VOID
%token STRUCT UNION ENUM ELLIPSIS

%token CASE DEFAULT IF ELSE SWITCH WHILE DO FOR GOTO CONTINUE BREAK RETURN

%token ASM

%token ID SELECTOR BOOLTYPE UNICHAR CLASS
%token AT_CLASS AT_PROTOCOL AT_INTERFACE AT_IMPLEMENTATION AT_END
%token AT_PRIVATE AT_PUBLIC AT_PROTECTED
%token AT_SELECTOR AT_ENCODE
%token AT_THROW AT_TRY AT_CATCH AT_FINALLY
%token IN OUT INOUT BYREF BYCOPY ONEWAY

%token AT_PROPERTY AT_SYNTHESIZE AT_OPTIONAL AT_REQUIRED WEAK STRONG
%token AT_SYNCHRONIZED AT_DEFS
%token AT_AUTORELEASEPOOL AT_UNSAFE_UNRETAINED AT_AUTORELEASING


%token IDENTIFIER
%token TYPE_NAME
%token CONSTANT
%token STRING_LITERAL
%token AT_STRING_LITERAL
%token AT_ARRAY_LITERAL

%start translation_unit

%%

asm_statement
	: ASM IDENTIFIER ';' { $$=node("asm", $2, 0); }
	;

/* FIXME: selectors can consist of *any* word (even if keyword like 'for', 'default') and not only IDENTIFIERs! */
// FIXME: should we merge the selector components into a single node value?

selector
	: { nokeyword=1; } IDENTIFIER { $$=node("selector", $1, 0); }
	| ':'  { $$=node("selector", leaf("identifier", ":"), 0); }
	| selector { nokeyword=1; } IDENTIFIER { $$=$1; append($1, $2); }	// checkme: this would be [obj method:arg suffix]
	| selector ':'  { $$=$1; append($1, leaf("identifier", ":")); }
	;

selector_with_arguments
	: { nokeyword=1; } IDENTIFIER { $$=node("selector", $1, 0); }
	| ':' expression  { $$=node("selector", $2, 0); }
	| selector_with_arguments { nokeyword=1; } IDENTIFIER { $$=$1; append($1, $2); }	// checkme: this would be [obj method:arg suffix]
	| selector_with_arguments ':' expression  { $$=$1; append($1, $3); }
	;

primary_expression
	: IDENTIFIER
	| CONSTANT
	| STRING_LITERAL
	| '(' expression ')'  { $$=node("parexpr", $2); }
	/* gcc extension */
	| '(' compound_statement ')'  { $$=node("statememtexpr", $2); }
	/* Obj-C extensions */
	| AT_STRING_LITERAL
	| AT_SELECTOR '(' selector ')'  { $$=$3; }
	| AT_ENCODE '(' type_name ')'  { $$=node("@encode", $3, 0); }
	| AT_PROTOCOL '(' IDENTIFIER ')'  { $$=node("@protocol", $3, 0); }
	| '[' expression selector_with_arguments ']'  { $$=node("methodcall", $2, $3, 0); }
	| AT_ARRAY_LITERAL { $$=node("arraylit", 0); }
	;

postfix_expression
	: primary_expression
	| postfix_expression '[' expression ']'  { $$=node("index", $1, $3, 0); }
	| postfix_expression '(' ')'  { $$=node("functioncall", $1, 0); }
	| postfix_expression '(' argument_expression_list ')'  { $$=node("functioncall", $1, $3, 0); }
	| postfix_expression '.' IDENTIFIER  { $$=node("structref", $1, $3, 0); }
	| postfix_expression PTR_OP IDENTIFIER  { $$=node("structderef", $1, $3, 0); }
	| postfix_expression INC_OP  { $$=node("postinc", $1, 0); }
	| postfix_expression DEC_OP  { $$=node("postdec", $1, 0); }
	;

argument_expression_list
	: assignment_expression	{ $$=node("expr", $1, 0); }
	| argument_expression_list ',' assignment_expression  { $$=$1; append($1, $3); }
	;

unary_expression
	: postfix_expression
// FIXME: is ++(char *) x really invalid and must be written as ++((char *) x)?
	| INC_OP unary_expression { $$=node("preinc", $2, 0); }
	| DEC_OP unary_expression { $$=node("predec", $2, 0); }
	| SIZEOF unary_expression { $$=node("sizeof", $2, 0); }
	| SIZEOF '(' type_name ')' { $$=node("sizeof", $2, 0); }
	| unary_operator cast_expression { $$=$1; append($$, $2); }
	;

unary_operator
	: '&'  { $$=leaf("addrof", NULL); }
	| '*'  { $$=leaf("deref", NULL); }
	| '+'  { $$=leaf("plus", NULL); }
	| '-'  { $$=leaf("minus", NULL); }
	| '~'  { $$=leaf("neg", NULL); }
	| '!'  { $$=leaf("not", NULL); }
	;

struct_component_expression
	: conditional_expression { $$=node("list", $1, 0); }
	| struct_component_expression ',' conditional_expression   { $$=$1; append($1, $2); }
	;
														
cast_expression
	: unary_expression
	| '(' type_name ')' cast_expression { $$=node("cast", $2, $4, 0); }
	| '(' type_name ')' '{' struct_component_expression '}'	 { $$=node("structlit", $2, $4, 0); }
	;

multiplicative_expression
	: cast_expression
	| multiplicative_expression '*' cast_expression { $$=node("mult", $1, $3); }
	| multiplicative_expression '/' cast_expression { $$=node("div", $1, $3); }
	| multiplicative_expression '%' cast_expression { $$=node("rem", $1, $3); }
	;

additive_expression
	: multiplicative_expression
	| additive_expression '+' multiplicative_expression { $$=node("add", $1, $3, 0); }
	| additive_expression '-' multiplicative_expression { $$=node("sub", $1, $3, 0); }
	;

shift_expression
	: additive_expression
	| shift_expression LEFT_OP additive_expression { $$=node("shl", $1, $3, 0); }
	| shift_expression RIGHT_OP additive_expression { $$=node("shr", $1, $3, 0); }
	;

relational_expression
	: shift_expression
	| relational_expression '<' shift_expression { $$=node("lt", $1, $3, 0); }
	| relational_expression '>' shift_expression { $$=node("gt", $1, $3, 0); }
	| relational_expression LE_OP shift_expression { $$=node("le", $1, $3, 0); }
	| relational_expression GE_OP shift_expression { $$=node("ge", $1, $3, 0); }
	;

equality_expression
	: relational_expression
	| equality_expression EQ_OP relational_expression { $$=node("eq", $1, $3, 0); }
	| equality_expression NE_OP relational_expression { $$=node("neq", $1, $3, 0); }
	;

and_expression
	: equality_expression
	| and_expression '&' equality_expression { $$=node("and", $1, $3, 0); }
	;

exclusive_or_expression
	: and_expression
	| exclusive_or_expression '^' and_expression { $$=node("xor", $1, $3, 0); }
	;

inclusive_or_expression
	: exclusive_or_expression
	| inclusive_or_expression '|' exclusive_or_expression { $$=node("or", $1, $3, 0); }
	;

logical_and_expression
	: inclusive_or_expression
	| logical_and_expression AND_OP inclusive_or_expression { $$=node("andif", $1, $3, 0); }
	;

logical_or_expression
	: logical_and_expression
	| logical_or_expression OR_OP logical_and_expression { $$=node("orif", $1, $3, 0); }
	;

conditional_expression
	: logical_or_expression
	| logical_or_expression '?' expression ':' conditional_expression { $$=node("conditional", $1, $3, $5, 0); }
	;

assignment_expression
	: conditional_expression
	| unary_expression assignment_operator assignment_expression  { $$=$2; append($2, $1); append($2, $3); }
	;

assignment_operator
	: '='   { $$=leaf("assign", NULL); }
	| MUL_ASSIGN   { $$=leaf("multassign", NULL); }
	| DIV_ASSIGN   { $$=leaf("divassign", NULL); }
	| MOD_ASSIGN   { $$=leaf("remassign", NULL); }
	| ADD_ASSIGN   { $$=leaf("addassign", NULL); }
	| SUB_ASSIGN   { $$=leaf("subassign", NULL); }
	| LEFT_ASSIGN   { $$=leaf("shlassign", NULL); }
	| RIGHT_ASSIGN   { $$=leaf("shrassign", NULL); }
	| AND_ASSIGN   { $$=leaf("andassign", NULL); }
	| XOR_ASSIGN   { $$=leaf("xorassign", NULL); }
	| OR_ASSIGN   { $$=leaf("orassign", NULL); }
	;

expression
	: assignment_expression{ $$=node("expr", $1, 0); }
	| expression ',' assignment_expression  { $$=$1; append($1, $2); }
	;

constant_expression
	: conditional_expression
	;

class_name_list
	: IDENTIFIER { $$=node("classname", $1, 0); }
	| class_name_list ',' IDENTIFIER  { $$=$1; append($1, $3); }
	;

class_with_superclass
	: IDENTIFIER { $$=node("classhierarchy", $1, 0); }
	| IDENTIFIER ':' IDENTIFIER  { $$=$1; append($1, $3); }
	;

category_name
	: IDENTIFIER
	;

inherited_protocols
	: protocol_list
	;

class_name_declaration
	: class_with_superclass { $$=node("class", $1, 0); }
	| class_with_superclass '<' inherited_protocols '>' { $$=node("class", $1, $3, 0); }
	| class_with_superclass '(' category_name ')'  { $$=node("class", $1, $3, 0); }
	| class_with_superclass '<' inherited_protocols '>' '(' category_name ')'  { $$=node("class", $1, $3, $5, 0); }
	| error
	;

class_or_instance_method_specifier
	: '+'  { $$=leaf("classmethod", NULL); }
	| '-'  { $$=leaf("instancemethod", NULL); }
	;

do_atribute_specifiers
	: do_atribute_specifier { $$=node("doattributes", $1, 0); }
	| do_atribute_specifiers do_atribute_specifier { $$=$1; append($1, $2); }	/* collect them */
	;

do_atribute_specifier
	: { objctype=1; } ONEWAY  { $$=leaf("oneway", NULL); }
	| { objctype=1; } IN  { $$=leaf("in", NULL); }
	| { objctype=1; } OUT  { $$=leaf("out", NULL); }
	| { objctype=1; } INOUT  { $$=leaf("inout", NULL); }
	| { objctype=1; } BYREF  { $$=leaf("byref", NULL); }
	| { objctype=1; } BYCOPY  { $$=leaf("bycopy", NULL); }
	;

objc_declaration_specifiers
	: do_atribute_specifiers type_name  { $$=node(" ", $1, $2); }
	| type_name
	;

selector_argument_declaration
	: '(' objc_declaration_specifiers ')' IDENTIFIER  { $$=node("argument", $2, $4, 0); }
	;

selector_with_argument_declaration
	: { nokeyword=1; } IDENTIFIER { $$=node("selector", $1, 0); }
	| ':' selector_argument_declaration  { $$=node("selector", $2, 0); }
	| selector_with_argument_declaration { nokeyword=1; } IDENTIFIER { $$=$1; append($1, $2); }	// checkme: this would be [obj method:arg suffix]
	| selector_with_argument_declaration ':' selector_argument_declaration  { $$=$1; append($1, $3); }

method_declaration
	: class_or_instance_method_specifier '(' objc_declaration_specifiers ')' selector_with_argument_declaration { $$=node("methoddeclaration", $1, $3, $5, 0); }
	;

method_declaration_list
	: method_declaration ';'  { $$=node("interface", $1, 0); }
	| AT_OPTIONAL method_declaration ';'  { append($2, $1); $$=node("interface", $2, 0); }
	| AT_REQUIRED method_declaration ';'  { append($2, $1); $$=node("interface", $2, 0); }
	| method_declaration_list method_declaration ';'  { $$=$1; append($1, $2); }
	| error ';'
	;

ivar_declaration_list
	: '{' struct_declaration_list '}'  { $$=node("{", $2, 0); }
	;

class_implementation
	: IDENTIFIER	{ $$=node("classimp", $1, 0); }
	| IDENTIFIER '(' category_name ')'  { $$=node("classimp", $1, $3, 0); }

method_implementation
	: method_declaration compound_statement  { $$=node("method", $1, $2, 0); }
	| method_declaration ';' compound_statement  { $$=node("method", $1, $3); }	/* ignore extra ; */
	;

method_implementation_list
	: method_implementation  { $$=node("implementation", $1, 0); }
	| method_implementation_list method_implementation  { $$=$1; append($1, $2); }
	;

objc_declaration
	: AT_CLASS class_name_list ';'	{ $$=node("forwardclass", $2, 0); }
		/* FIXME: do for all class names in the list! */
//		setRight($2, $$);	/* this makes it a TYPE_NAME since $2 is the symbol table entry */
	| AT_PROTOCOL class_name_declaration AT_END  { $$=node("@protocol", $2, 0); }
	| AT_PROTOCOL class_name_declaration method_declaration_list AT_END  { $$=node("@protocol", $2, $3, 0); }
	| AT_INTERFACE class_name_declaration AT_END  { $$=node("@interface", $2, 0); }
	| AT_INTERFACE class_name_declaration ivar_declaration_list AT_END  { $$=node("@interface", $2, $3, 0); }
	| AT_INTERFACE class_name_declaration ivar_declaration_list method_declaration_list AT_END  { $$=node("@interface", $2, $3, $4, 0); }
	| AT_IMPLEMENTATION class_implementation AT_END  { $$=node("@implementation", $2, 0); }
	| AT_IMPLEMENTATION class_implementation ivar_declaration_list AT_END  { $$=node("@implementation", $2, $3, 0); }
	| AT_IMPLEMENTATION class_implementation method_implementation_list AT_END  { $$=node("@implementation", $2, $3, 0); }
	| AT_IMPLEMENTATION class_implementation ivar_declaration_list method_implementation_list AT_END  { $$=node("@implementation", $2, $3, $4, 0); }
	;

declaration
	: asm_statement
	| declaration_specifiers ';'  { $$=node(";", $1, 0); }
	| declaration_specifiers { currentDeclarationSpecifier=$1; } init_declarator_list ';'  { $$=$3; }
	| objc_declaration
	;

/* a type can be a mix of storage class, types and qualifiers (e.g. const) */

declaration_specifiers
	: storage_class_specifier
	| storage_class_specifier declaration_specifiers
	| type_specifier_list declaration_specifiers  { $$=node(" ", $1, $2); }
	| storage_class_specifier type_specifier_list declaration_specifiers  { $$=node(" ", $1, 0); }
	| type_specifier_list storage_class_specifier declaration_specifiers  { $$=node(" ", $1, 0); }
	| type_qualifier
	| type_qualifier declaration_specifiers  { $$=node(" ", $1, 0); }
	;

init_declarator_list
	: init_declarator
	| init_declarator_list ',' init_declarator  { $$=node(",", $1, $3); }
	;

init_declarator
	: declarator { /* process declarator, expecially typedef */ }
	| declarator '=' initializer  { /* check if it can be initialized */ $$=node("=", $1, $3); }
	;

storage_class_specifier
	: TYPEDEF { $$=leaf("typedef", NULL); }
	| EXTERN { $$=leaf("extern", NULL); }
	| STATIC { $$=leaf("static", NULL); }
	| AUTO { $$=leaf("auto", NULL); }
	| REGISTER { $$=leaf("register", NULL); }
	;

protocol_list
	: IDENTIFIER  { /* save identifier */ }
	| protocol_list ',' IDENTIFIER  { $$=node(",", $1, $3); }

type_specifier_list
	: type_specifier { $$=$1; }
	| type_specifier type_specifier_list { /*setRight($1, $2);*/ $$=$1; }

type_specifier
	: VOID	{ $$=leaf("void", NULL); }
	| CHAR	{ $$=leaf("char", NULL); }
	| SHORT	{ $$=leaf("short", NULL); }
	| INT	{ $$=leaf("int", NULL); }
	| LONG	{ $$=leaf("long", NULL); }
	| FLOAT	{ $$=leaf("float", NULL); }
	| DOUBLE	{ $$=leaf("double", NULL); }
	| SIGNED	{ $$=leaf("signed", NULL); }
	| UNSIGNED	{ $$=leaf("unsigned", NULL); }
	| struct_or_union_specifier
	| enum_specifier
	| { typename=1; } TYPE_NAME '<' protocol_list '>'	{ $$=node("type", $3, 0); }
	| { typename=1; } TYPE_NAME	{ $$=node("type", 0); }
	;

struct_or_union
	: STRUCT	{ $$=leaf("struct", NULL); }
	| UNION		{ $$=leaf("union", NULL); }
	;

struct_or_union_specifier
	: struct_or_union IDENTIFIER '{' struct_declaration_list '}'  { $$=node("struct", $1, $2, $4, 0); /* accept only forward defines */ /* setkeyval(structNames, name($2), $$); */ }
	| struct_or_union '{' struct_declaration_list '}'  { $$=node("struct", $1, leaf("identifier", "@anonymous@"), $3, 0); }
	| struct_or_union IDENTIFIER { /* lookup in structNames or forward-define */ $$=node("struct", $2, 0); }
	;

struct_declaration_list
	: struct_declaration  { $$=node("structdecl", $1, 0); }
	| struct_declaration_list struct_declaration  { $$=$1; append($1, $2); }
	;

property_attributes_list
	: IDENTIFIER	{ $$=node("propattribs", $1, 0); }
	| IDENTIFIER ',' property_attributes_list  { $$=$1; append($1, $3); }
	;

struct_declaration
	: specifier_qualifier_list struct_declarator_list ';'  { $$=node("structdecl", $1, $2, 0); }
	| protection_qualifier specifier_qualifier_list struct_declarator_list ';'  { $$=node(";", node(" ", node(" ", $1, $2), $3), 0); }
	| property_qualifier specifier_qualifier_list struct_declarator_list ';'  { $$=node(";", node(" ", node(" ", $1, $2), $3), 0); }
	| AT_SYNTHESIZE ivar_list ';'  { $$=node("@synthesize", $2, 0); }
	| AT_DEFS '(' IDENTIFIER ')' { $$=node("@defs", $2, 0); }
	;

protection_qualifier
	: AT_PRIVATE
	| AT_PUBLIC
	| AT_PROTECTED
	;

property_qualifier
	: AT_PROPERTY '(' property_attributes_list ')'  { $$=node("(", $1, $3); }
	| AT_PROPERTY
	;

ivar_list
	: ivar_list IDENTIFIER  { $$=node(" ", $1, $2); }
	| IDENTIFIER
	;

specifier_qualifier_list
	: type_specifier specifier_qualifier_list  { $$=node(" ", $1, $2); }
	| type_specifier
	| type_qualifier specifier_qualifier_list  { $$=node(" ", $1, $2); }
	| type_qualifier
	;

struct_declarator_list
	: struct_declarator
	| struct_declarator_list ',' struct_declarator  { $$=node(",", $1, $3); }
	;

struct_declarator
	: declarator
	| ':' constant_expression  { $$=node(":", 0, $2); }
	| declarator ':' constant_expression  { $$=node(":", $1, $3); }
	;

enum_specifier
	: ENUM '{' enumerator_list '}'
	| ENUM IDENTIFIER '{' enumerator_list '}'
	| ENUM IDENTIFIER
	;

enumerator_list
	: enumerator
	| enumerator_list ',' enumerator  { $$=node(",", $1, $3); }
	;

enumerator
	: IDENTIFIER
	| IDENTIFIER '=' constant_expression  { $$=node("=", $1, $3); }
	;

type_qualifier
	: CONST
	| VOLATILE
	| WEAK
	| STRONG
	;

declarator
	: pointer direct_declarator  { $$=node(" ", $1, $2); }
	| direct_declarator
	;

direct_declarator
	: IDENTIFIER { $$=declaratorName=$1; }
	| '(' declarator ')'  { $$=node("(", 0, $2); }
	| direct_declarator '[' constant_expression ']'  { $$=node("[", $1, $3); }
	| direct_declarator '[' ']'  { $$=node("[", $1, 0); }
	| direct_declarator '(' parameter_type_list ')'  { $$=node("(", $1, $3); }
	| direct_declarator '(' identifier_list ')'  { $$=node("(", $1, $3); }
	| direct_declarator '(' ')'  { $$=node("(", $1, 0); }
	;

pointer
	: '*' { $$=node("*", 0, 0); }
	| '*' type_qualifier_list  { $$=node("*", 0, $2); }
	| '*' pointer  { $$=node("*", 0, $2); }
	| '*' type_qualifier_list pointer  { $$=node("*", $2, $3); }
	;

type_qualifier_list
	: type_qualifier
	| type_qualifier_list type_qualifier  { $$=node(" ", $1, $2); }
	;


parameter_type_list
	: parameter_list
	| parameter_list ',' ELLIPSIS  { $$=node(",", $1, node("...", 0, 0)); }
	;

parameter_list
	: parameter_declaration
	| parameter_list ',' parameter_declaration  { $$=node(",", $1, $3); }
	;

parameter_declaration
	: declaration_specifiers declarator  { $$=node(" ", $1, $2); }
	| declaration_specifiers abstract_declarator  { $$=node(" ", $1, $2); }
	| declaration_specifiers
	;

identifier_list
	: IDENTIFIER
	| identifier_list ',' IDENTIFIER  { $$=node(",", $1, $3); }
	;

type_name
	: specifier_qualifier_list
	| specifier_qualifier_list abstract_declarator  { $$=node(" ", $1, $2); }
	;

abstract_declarator
	: pointer
	| direct_abstract_declarator
	| pointer direct_abstract_declarator  { $$=node(" ", $1, $2); }
	;

direct_abstract_declarator
	: '(' abstract_declarator ')' { $$=node("(", 0, $2); }
	| '[' ']'  { $$=node("[", 0, 0); }
	| '[' constant_expression ']'  { $$=node("[", 0, $2); }
	| direct_abstract_declarator '[' ']'  { $$=node("[", $1, 0); }
	| direct_abstract_declarator '[' constant_expression ']'  { $$=node("[", $1, $2); }
	| '(' ')'  { $$=node("(", 0, 0); }
	| '(' parameter_type_list ')'  { $$=node("(", 0, $2); }
	| direct_abstract_declarator '(' ')'  { $$=node("(", $1, 0); }
	| direct_abstract_declarator '(' parameter_type_list ')'  { $$=node("(", $1, $2); }
	;

initializer
	: assignment_expression
	| '{' initializer_list '}'  { $$=node("{", 0, $2); }
	| '{' initializer_list ',' '}'  { $$=node("{", 0, $2); }	/* removes extra , */
	;

initializer_list
	: initializer
	| initializer_list ',' initializer  { $$=node(",", $1, $3); }
	;

statement
	: labeled_statement
	| compound_statement
	| expression_statement
	| selection_statement
	| iteration_statement
	| jump_statement
	| asm_statement
	| AT_TRY compound_statement catch_sequence finally
	| AT_THROW ';'	// rethrow within @catch block
	| AT_THROW expression ';'
	| AT_SYNCHRONIZED '(' expression ')' compound_statement
	| AT_AUTORELEASEPOOL compound_statement
	| error ';' 
	| error '}'
	;

catch_sequence
	: AT_CATCH compound_statement{ $$=node("@catch", 0, 0); }
	| catch_sequence AT_CATCH compound_statement{ $$=node("@catch", 0, 0); }
	;

finally
	: AT_FINALLY compound_statement
	;

labeled_statement
	: IDENTIFIER ':' statement  { $$=node(":", $1, $3); }
	| CASE constant_expression ':' statement  { $$=node("case", $2, $4); }
	| DEFAULT ':' statement  { $$=node("default", 0, $3); }
	;

compound_statement
	: '{' '}'  { $$=node("{", 0, 0); }
    | '{' { pushscope(); } statement_list '}'  { pushscope(); $$=node("{", 0, $2); }
	;

statement_list
	: declaration
	| statement
	| statement_list statement  { $$=node(" ", $1, $2); }
	;

expression_statement
	: ';'  { $$=node("statement", 0); }
	| expression ';'  { $$=node("statement", $1, 0); }
	;

selection_statement
	: IF '(' expression ')' statement
		{
		$$=node("if", $3, $5);
		}
	| IF '(' expression ')' statement ELSE statement
		{
		$$=node("if",
				$3,
				node("else", $5, $7)
				);
		}
	| SWITCH '(' expression ')' statement  { $$=node("switch", $3, $5); }
	;

iteration_statement
	: WHILE '(' expression ')' statement  { $$=node("while", $3, $5); }
	| DO statement WHILE '(' expression ')' ';'  { $$=node("do", $5, $3); }
	| FOR '(' expression_statement expression_statement ')' statement
		{
		$$=node("for",
				node(";", $3, $4),
				$6);
		}
	| FOR '(' expression_statement expression_statement expression ')' statement
		{
		$$=node("for",
				node(";",
					 $3,
					 node(";", $4, $5)
					 ), 
				$7);
		}
	| FOR '(' declaration expression_statement expression ')' statement	
		{
		$$=node("{",
				$3,
				node("for",
					 node(";",
						  0,
						  node(";", $4, $5)
						  ),
					 $7)
				);
		}
	| FOR '(' declaration IN expression ')' statement
		{
		$$=node("{",
				$3,
				node("forin",
					 $5,
					 $7)
				);
		}
	;

jump_statement
	: GOTO IDENTIFIER ';'  { $$=node(";", node("goto", 0, $2), 0); }
	| CONTINUE ';'  { $$=node(";", node("continue", 0, 0), 0); }
	| BREAK ';' { $$=node(";", node("break", 0, 0), 0); }
	| RETURN ';' { $$=node(";", node("return", 0, 0), 0); }
	| RETURN expression ';' { $$=node(";", node("return", 0, $2), 0); }
	;

function_definition
	: declaration_specifiers declarator compound_statement { $$=node(" ", node(" ", $1, $2), $3); }
	| declarator compound_statement { $$=node(" ", $1, $2); }
	;

external_declaration
	: function_definition
	| declaration
	;

// allow to notify the delegate for each translation unit and clean up memory from nodes we don't need any more

translation_unit
	: external_declaration { rootnode=$1; /* notify delegate */ }
	| translation_unit external_declaration { rootnode=node(" ", rootnode, $2); /* notify delegate */ }
	;

%%

extern char *yytext;
extern int line, column;

yyerror(s)
char *s;
{
	// forward to AST delegate (if it exists)
	fflush(stdout);
	printf("#error line %d column %d\n", line, column);
	printf("/* %s\n * %*s\n * %*s\n*/\n", yytext, column, "^", column, s);
	fflush(stdout);
}

