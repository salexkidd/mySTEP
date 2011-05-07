/* ObjC-2.0 scanner - based on http://www.lysator.liu.se/c/ANSI-C-grammar-l.html */
/* part of ocpp - an obj-c preprocessor */

	/* digit */
D			[0-9]
	/* letter */
L			[a-zA-Z_$]
	/* hex letter */
H			[a-fA-F0-9]
	/* exponent */
E			[Ee][+-]?{D}+
	/* float suffix */
FS			(f|F|l|L)
	/* int suffix */
IS			(u|U|l|L)*

%{
#include <stdio.h>
#include "y.tab.h"
#include "node.h"
	
#define error(X)
	
void count(void);
void comment(int cxx);

int column = 0;
int line = 1;	
	
struct RESERVED
	{
		char *word;
		int token;
	} reserved[]={
	"auto", AUTO, 
	"break", BREAK, 
	"case", CASE, 
	"char", CHAR, 
	"const", CONST, 
	"continue", CONTINUE, 
	"default", DEFAULT, 
	"do", DO, 
	"double", DOUBLE, 
	"else", ELSE, 
	"enum", ENUM, 
	"extern", EXTERN, 
	"float", FLOAT, 
	"for", FOR, 
	"goto", GOTO, 
	"if", IF, 
	"int", INT, 
	"long", LONG, 
	"register", REGISTER, 
	"return", RETURN, 
	"short", SHORT, 
	"signed", SIGNED, 
	"sizeof", SIZEOF, 
	"static", STATIC, 
	"struct", STRUCT, 
	"switch", SWITCH, 
	"typedef", TYPEDEF, 
	"union", UNION, 
	"unsigned", UNSIGNED, 
	"void", VOID, 
	"volatile", VOLATILE, 
	"while", WHILE, 
	
	/* Obj-C 1.0 extensions */
	
	"@interface", AT_INTERFACE, 
	"@implementation", AT_IMPLEMENTATION, 
	"@end", AT_END, 
	"@class", AT_CLASS, 
	"@protocol", AT_PROTOCOL, 
	"@selector", AT_SELECTOR, 
	"@encode", AT_ENCODE, 
	"@catch", AT_CATCH, 
	"@try", AT_TRY, 
	"@protected", AT_PROTECTED, 
	"@private", AT_PRIVATE, 
	"@public", AT_PUBLIC, 
	"inout", INOUT, 
	"in", IN, 
	"out", OUT, 
	"byref", BYREF, 
	"bycopy", BYCOPY, 
	"oneway", ONEWAY, 
	
	"id", ID, 
	"SEL", SEL, 
	"BOOL", BOOL, 
	"unichar", UNICHAR, 
	"Class", CLASS, 
	
	/* Obj-C 2.0 extensions */
	
	"@property", AT_PROPERTY, 
	"@synthesize", AT_SYNTHESIZE, 
	"@optional", AT_OPTIONAL, 
	"@required", AT_REQUIRED, 
	"__weak", WEAK, 
	"__strong", STRONG
	};
	
int symtab[11*19];	// hash table
	
int lookup(char *word)
	{ // look up identifier
		int hash=0;
		char *h=word;
		int s;
		while(*h)
			hash=2*hash+(*h++);
		hash%=sizeof(symtab)/sizeof(symtab[0]);
		s=symtab[hash];	// get first entry
		while(s)
			{
				if(strcmp(name(s), word) == 0)
					return s;	// found
				s=next(s);	// go to next symtab node
			}
		s=leaf(IDENTIFIER, word);
		setNext(s, symtab[hash]);
		symtab[hash]=s;	// prepend new entry
		return s;
	}

void scaninit(void)
	{
		int i;
		for(i=0; i<sizeof(reserved)/sizeof(reserved[0]); i++)
			setType(lookup(reserved[i].word), reserved[i].token);	// initialize all reserved words in symbol table
	}
	
%}

%%

"/*"			{ comment(0); }
"//"			{ comment(1); }

	/* identifiers and keywords */

{L}({L}|{D})*  { 
	int s;
	count();
	s=lookup(yytext); 
	yylval=s;
	if(right(s))
		return TYPE_NAME;	// syntactically we are a type name
	return type(s); 
} 

	/* numeral CONSTANTs */
0[xX]{H}+{IS}?		{ count(); yylval=cons(yytext); return(CONSTANT); }
0{D}+{IS}?			{ count(); yylval=cons(yytext); return(CONSTANT); }
{D}+{IS}?			{ count(); yylval=cons(yytext); return(CONSTANT); }
L?'(\\.|[^\\'])+'	{ count(); yylval=cons(yytext); return(CONSTANT); }

{D}+{E}{FS}?		{ count(); yylval=cons(yytext); return(CONSTANT); }
{D}*"."{D}+({E})?{FS}?	{ count(); yylval=cons(yytext); return(CONSTANT); }
{D}+"."{D}*({E})?{FS}?	{ count(); yylval=cons(yytext); return(CONSTANT); }

	/* string CONSTANTs */

L?\"(\\.|[^\\"])*\"	{ count(); yylval=cons(yytext); return(STRING_LITERAL); }
@\"(\\.|[^\\"])*\"			{ count(); yylval=cons(yytext); return(AT_STRING_LITERAL); }

	/* standard operators */

"..."			{ count(); return(ELLIPSIS); }
">>="			{ count(); return(RIGHT_ASSIGN); }
"<<="			{ count(); return(LEFT_ASSIGN); }
"+="			{ count(); return(ADD_ASSIGN); }
"-="			{ count(); return(SUB_ASSIGN); }
"*="			{ count(); return(MUL_ASSIGN); }
"/="			{ count(); return(DIV_ASSIGN); }
"%="			{ count(); return(MOD_ASSIGN); }
"&="			{ count(); return(AND_ASSIGN); }
"^="			{ count(); return(XOR_ASSIGN); }
"|="			{ count(); return(OR_ASSIGN); }
">>"			{ count(); return(RIGHT_OP); }
"<<"			{ count(); return(LEFT_OP); }
"++"			{ count(); return(INC_OP); }
"--"			{ count(); return(DEC_OP); }
"->"			{ count(); return(PTR_OP); }
"&&"			{ count(); return(AND_OP); }
"||"			{ count(); return(OR_OP); }
"<="			{ count(); return(LE_OP); }
">="			{ count(); return(GE_OP); }
"=="			{ count(); return(EQ_OP); }
"!="			{ count(); return(NE_OP); }
";"				{ count(); return(';'); }
("{"|"<%")		{ count(); return('{'); }
("}"|"%>")		{ count(); return('}'); }
","				{ count(); return(','); }
":"				{ count(); return(':'); }
"="				{ count(); return('='); }
"("				{ count(); return('('); }
")"				{ count(); return(')'); }
("["|"<:")		{ count(); return('['); }
("]"|":>")		{ count(); return(']'); }
"."				{ count(); return('.'); }
"&"				{ count(); return('&'); }
"!"				{ count(); return('!'); }
"~"				{ count(); return('~'); }
"-"				{ count(); return('-'); }
"+"				{ count(); return('+'); }
"*"				{ count(); return('*'); }
"/"				{ count(); return('/'); }
"%"				{ count(); return('%'); }
"<"				{ count(); return('<'); }
">"				{ count(); return('>'); }
"^"				{ count(); return('^'); }
"|"				{ count(); return('|'); }
"?"				{ count(); return('?'); }
 
[\n]			{ line++, column=0; }
[ \t\v\f]		{ count(); }
 
.				{ count(); error( "bad character" ); }

%%
 
 int yywrap()
 {
	 return(1);
 }
 
 
 void comment(int cxx)
 {
	 char c;
	if(cxx)
		{ // C++ comment
		while ((c = input()) != '\n' && c != EOF)
			/*putchar(c)*/;
		line++;
		return;
		}
	 while ( 1 )
		 {
		 while ( (c = input()) != '*' && c != EOF )
			 { /* eat up text of comment */
			 if(c == '\n')
				 line++;
			 }
		 if ( c == '*' )
			 {
			 while ( (c = input()) == '*' )
				 ;
			 if ( c == '/' )
				 break;    /* found the end */
			 }
		 
		 if ( c == EOF )
			 {
			 error( "EOF in comment" );
			 break;
			 }
		 }
 }
 
 void count(void)
 { // cound characters so that we know the column position
	 int i;
	 
	 for (i = 0; yytext[i] != '\0'; i++)
		 if (yytext[i] == '\n')
			 column = 0;
		 else if (yytext[i] == '\t')
			 column += 8 - (column % 8);
		 else
			 column++;
	 
//	 ECHO;
 }

int cons(char *str)
{
	return leaf(CONSTANT, str);
}