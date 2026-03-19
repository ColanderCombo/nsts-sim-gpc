{
  var n = options.balNodes;
  var ctx = new n.BalContext(options);
}

start = program
program = s:statementLine+ se:statementLast
        {
          var sNonNull = s.filter(function(x) { return x != null; });
          var stmts;
          if (se != null) {
            stmts = sNonNull.concat(se);
          } else {
            stmts = sNonNull;
          }
          ctx.exec(stmts);
          return ctx;
        }
        / s:statementLast                     { return [s]; }

statementLine = s:statement _ '\n' { return s; }
statementLast = s:statement _ '\n'? { return s; }

// http://bitsavers.trailing-edge.com/pdf/ibm/360/asm/C28-6514-5_IBM_System_360_Assembler_Language_Level_E_F_Dec67.pdf
//
//
// Character Set (p.10)
//
// Source statements are written using the following characters:
//
// Letters              A through Z, and $, #, @
//
letter = [A-Z$#@]
//
// Digits               0 through 9
//
digit = [0-9]
//
// Special characters   + - , = . * () ' /  & blank
//
specialChar = [+-,=.*\(\)'/& ]

//
// These characters are represented by the
// card-punch combinations and internal bit
// configurations listed in Appendix A. In
// addition, any of the 256 punch combinations
// may be designated anywhere that characters
// may appear between paired apostrophes:, in
// comments, and in macro instruction operands.
//
// TERMS AND EXPRESSIONS (p.10)
//
// TERMS
//
// Every term represents a value. This
// value may be assigned by the assembler
// (symbols" symbol length attribute, location
// counter reference) or may be inherent in
// the term itself (self-defining term,
// literal).
//
// An arithmetic combination of terms is
// reduced to a single value by the assembler.
//
// The following material discusses each
// type of term and the rules for its use.
//
// SYMBOLS
//
// A symbol is a character or combination of
// characters used to represent locations or
// arbitrary values. Symbols, through their
// use in name fields and in operands, provide
// the programmer with an efficient way to
// name and reference a program element.
// There are three types of symbols:
///
// 1. Ordinary symbols.
// 2. Variable symbols.
// 3. Sequence symbols.
//
symbol = ordinary_symbol
       / variable_symbol
       / sequence_symbol
//
// Ordinary symbols, created by the programmer
// for use as a name entry and/or an
// operand, must conform to these rules:
//
// 1. The symbol must not consist of more
//    than eight characters. The first
//    character must be a letter. The other
//    characters may be letters, digits, or
//    a combination of the two.
// 2. No special characters may be included
//      in a symbol.
// 3. No blanks are allowed in a symbol.
//
//ordinary_symbol = letter (letter/digit)*
ordinary_symbol = [A-Z$#@][A-Z$#@0-9]*        { return text(); }
//
// Variable symbols must begin with an
// ampersand (&) followed by one to seven
// letters and/or numbers, the first of which
// must be a letter. Variable symbols are
// used within the source program or macro
// definition to allow different values to be
// assigned to one symbol. A complete discussion
// of variable symbols appears in
// Section 6.
//
//variable_symbol = '&' letter (letter/digit)*
variable_symbol = '&' [A-Z$#@][A-Z$#@0-9]*     { return text(); }

//
// Sequence symbols consist of a period (.)
// followed by one to seven letters and/or
// numbers, the first of which must be a letter.
// Sequence symbols are used to indicate
// the position of statements within the
// source program or macro definition. Through
// their use the programmer can vary the
// sequence in which statements are processed
// by the assembler program. (See the complete
// discussion in Section 6~)
//
//sequence_symbol = '.' letter (letter/digit)*
sequence_symbol = '.' [A-Z$#@][A-Z$#@0-9]*     { return text(); }
//
//
// Self-Defining Terms (p.12)
//
// A self-defining term is one whose value
// is inherent in the term. It is not
// assigned a value by the assembler. For
// example, the decimal self-defining term - 15 - represents a value of 15. The length
// attribute of a self-defining term is always
// 1.
//
// There are four types of self-defining
// terms: decimal., hexadecimal, binary, and
// character. Use of these terms is spoken of
// as decimal, hexadecimal, binary, or character
// representation of the machine-language
// binary value or bit configuration they
// represent.
//
self_defining_term = decimal_term
                   / hexadecimal_term
                   / binary_term
                   / character_term
                   / halfword_term
                   / fullword_term
                   / ycon_term
                   / zcon_term
//
// Decimal Self-Defining Term: A decimal
// self-defining term is simply an unsigned
// decimal number written as a sequence of
// decimal digits. High-order zeros may be
// used (e.g., 007). Limitations on the value
// of the term depend on its use. For example,
// a decimal term that designates a
// general register should have a value
// between 0 and 15; one that represents an
// address should not exceed the size of
// storage. In any case, a decimal term may
// not consist of more than eight digits, or
// exceed 16,777.,215 (224-1). A decimal selfdefining
// term is assembled as its binary
// equi~alent. Some examples of decimal selfdefining
// terms are: 8, 147, 4092, and
// 00021.
//
decimal_term = digit+                   { return new n.Constant('DECIMAL',parseInt(text(), 10),text().length); }
//
// Hexadecimal Self-defining Term: A hexa-
// decimal self-defining term consists of one
// to six hexadecimal digits enclosed by
// apostrophes and preceded by the letter X:
// X'C49'.
//
hexadecimal_term = 'X' '\'' d:hexadecimal_digit+ '\'' { return new n.Constant('HEX',d.join(''), d.length); }
hexadecimal_digit = [0-9A-F]
//
// Binary Self-Defining Term: A binary selfdefining
// term is written as an unsigned
// sequence of Is and Os enclosed in
// apostrophes and preceded by the letter B,
// as follows: B'10001101'. This term would
// appear in storage as shown, occupying one
// byte. A binary term may have up to 24 bits
// represented
//
binary_term = 'B' '\'' d:binary_digit+ '\'' { return new n.Constant('BINARY', parseInt(d.join(""),2),d.length); }
binary_digit = [01]

halfword_term = 'H' '\'' d:digit+ '\'' { return new n.Constant('HALFWORD', parseInt(d.join(""),10),1); }
              / 'H' '\'' d:digit+  ',' d2:digit+ '\''
              { return new n.Constant('FULLWORD', (parseInt(d.join(""),10)<<16)+parseInt(d2.join(""),10),2); }

fullword_term = 'H' '\'' d:digit+ '\''
              { return new n.Constant('FULLWORD', parseInt(d.join(""),10), 2); }

ycon_term = 'Y' '\'' d:hexadecimal_digit+ '\'' { return new n.Constant('HEX',d.join(""), 4); }
zcon_term = 'Z' '\'' d:hexadecimal_digit+ '\'' { return new n.Constant('HEX',d.join(""), 8); }

//
// Character Self-Defining Term: A character
// self-defining term consists of one to three
// characters enclosed by apostrophes. It
// must be preceded by the letter C. All
// letters, decimal digits, and special characters
// may be used in a character term. In
// addition" any of the remainder of the 256
// punch combinations may be designated in a
// character self-defining term. Examples of
// character self-defining terms are as follows:
//
// C'/'     C' ' (blank)
// C'ABC'   C'13'
//
// Because of the use of apostrophes in the
// assembler language and ampersands in the
// macro language as syntactic characters, the
// following rule must be observed when using
// these characters in a character term.
// For each apostrophe or ampersand desired
// in a character self-defining term, two
// apostrophes or ampersands must be written.
// For example, the character value A'# would
// be written as 'A''#', while an apostrophe
// followed by a blank and another single
// apostrophe would be written as ''' '''.
//
// Each character in the character sequence
// is assembled as its eight-bit code equivalent
// (see Appendix A). The two apostrophes
// or ampersands that must be used to represent
// an apostrophe or ampersand within
// the character sequence are assembled as an
// apostrophe or ampersand.
//
character_term = 'C' "'" str:(("''"/[^'])*) "'"
            {
              return str.join("").replace(/\'\'/g,"'").replace(/&&/g,"&");
            }
//
// Location Counter Reference
//
// The programmer may refer to the current
// value of the location counter at any place
// in a program by using an asterisk as a term
//
location_counter_reference = '*' { return {location_counter_reference: true}; }
//
// Literals
//
// A literal term is one of three basic
// ways to introduce data into a program. It
// is simply a constant preceded by an equal
// sign (=).
//
// A literal represents data rather than a
// reference to data. The appearance of a
// literal in a statement directs the assembler
// program to assemble the data specified
// by the literal, store this data in a
// "literal pool," and place the address of
// the storage field containing the data 1n
// the operand field of the assembled statement.
//
// Literals provide a means of entering
// constants (such as numbers for calculation,
// addresses, indexing factors, or words or
// phrases for printing out a message) into a
// program by specifying the constant in the
// operand of the instruction in which it is
// used. This is in contrast to using the DC
// assembler instruction to enter the data
// into the program and then using the name of
// the DC instruction in the operand. Only
// one literal is allowed in a machine-
// instruction statement.
//
// A literal term may not be combined with
// any other terms.
//
// A literal may not be used as the
// receiving field of an instruction that
// modifies storage.
//
// A literal may not be specified in an
// address constant (see Section 5, DC--Define
// Constant).
//
// (p.15)
// Literal Format: The assembler requires a
// description of the type of literal being
// specified as well as the literal itself.
// This descriptive information assists the
// assembler in assembling the literal correctly.
// The descriptive portion of the
// literal must indicate the format of the
// constant. It may also specify the length
// of the constant.
//
// The method of describing and specifying
// a constant as a literal is nearly identical
// to the method of specifying it in the
// operand of a DC assembler instruction. The
// major difference is that the literal must
// start with an equal sign (=), which indicates
// to the assembler that a literal
// follows. The reader is referred to the
// discussion of the DC assembler instruction
// operand format (Section 5) for the means of
// specifying a literal. The type of literal
// designated in an instruction is not checked
// for correspondence with the operation code
// of the instruction.
//
// Some examples of literals are:
// =A(BETA)     -- address constant literal.
// =F'1234'     -- a fixed-point number with
///             -- a length of four bytes.
// =C'ABC'      --
//
literal = '=' t:self_defining_term { return new n.Literal(t); }
//
// Symbol Length Attribute Reference
//
// The length attribute of a symbol may be
// used as a term. Reference to the attribute
// is made by coding L' followed by the
// symbol, as in:
// L'BETA
//
symbol_length_attribute_reference = 'L' "'" s:symbol { return {symbolLength:s}; }
//
// Terms in Parentheses
//
// Terms in parentheses are reduced to a
// single value; thus, the terms in parentheses,
// in effect, become a single term.
//
// Terms in parentheses may be included
// within a set of terms in parentheses:
//
// A+B-CC+D-CE+F)+10)
//
// The innermost set of terms in parentheses
// is evaluated first. Five levels of
// parentheses are allowed; a level of parentheses
// is a left parenthesis and its corresponding
// right parenthesis. Parentheses
// which occur as part of an operand format do
// not count in this limit. An arithmetic
// combination of terms is evaluated as described
// in the next section "Expressions."
//
// EXPRESSIONS
// This subsection discusses the expressions
// used in coding operand entries for source statements. Two types of expressions,
// absolute and relocatable, are presented
// along with the rules for determining
// these attributes of an expression
//
// An expression is commposed of a single term
// or an arithmetic combination of terms. The
// following are examples of valid expressions:
//
// *                    BETA*10
// AREA1+X'2D'          B'101'
// *+32                 C'ABC'
// N-25                 29
// FIELD+332            L'FIELD'
// FIELD                LMABDA+GAMMA
// (EXIT-ENTRY+1)+GO    TEN/TWO
// =F'1234'
// ALPHA-BETA/(10+AREA*L'FIELD)-100
//
// The rules for Coding expressions are:
//
// 1. An expression cannot start with an
//    arithmetic operator, ( +-/* ). Therefore,
//    the expression -A+BETA is invalid.
//    However, the expression 0-A+BETA
//    is valid.
//
// 2. An expression cannot contain two
//    terms or two operators in succession.
//
// 3. An expression cannot: consist of more
//    than 16 terms.
//
// 4. An expression cannot have more than
//    five levels of parentheses.
// 5. A multi term expression cannot contain a literal.
//
expression = e:expr_addsub { return new n.Expression(e); }
expr_addsub = x:expr_muldiv y:(_ ('+'/'-') _ expr_muldiv)+ { return n.LA('ADD', x,y,3); }
            / x:expr_muldiv                            { return x; }
expr_muldiv = x:expr_primary y:(_ ('*'/'/') _ expr_primary)+ { return n.LA('MUL', x,y,3); }
            / x:expr_primary                             { return x; }

expr_primary = x:term
                {
                  return x;
                }
             / '(' e:expr_addsub ')' { return e; }
term = termElem

termElem = literal
         / exprSelfTerm
         / l:location_counter_reference         { return new n.LocCountRef();  }
         / s:symbol_length_attribute_reference  { return new n.SymbolLengthAttr(s); }
         / s:symbol                             { return new n.Var(s); }


//         / s:symbol                             { return new n.Symbol(s); }

exprSelfTerm = decTerm
             / hexTerm
             / binTerm
             / charTerm
             / flt32Term
             / flt64Term

decTerm = '-' d:[0-9]+           { return new n.SelfDefTerm(-parseInt(d.join(''),10)); }
        / d:[0-9]+               { return new n.SelfDefTerm(parseInt(d.join(''),10)); }
hexTerm = 'X\'' d:[0-9A-F]+ '\'' { return new n.SelfDefTerm(parseInt(d.join(''),16)); }
binTerm = 'B\'' d:[01]+ '\''     { return new n.SelfDefTerm(parseInt(d.join(''),2)); }
charTerm = 'C\'' c:[^.]+ '\''    { return n.SelfDefTerm.makeChar(c); }
flt32Term = 'E\'' f:floatConst '\'' { return new n.SelfDefTerm(new n.FloatSingleConstant(f)); }
flt64Term = 'D\'' f:floatConst '\'' { return new n.SelfDefTerm(new n.FloatDoubleConstant(f)); }


//baseTerm = d:termElem '(' b:termElem ')' { return new n.Arg({d:d,b:b}); }
//baseIndexTerm = d:termElem '(' i:termElem ',' b:termElem ')' { return new n.Arg({d:d, i:i, b:b}); }

operands = head:operand rest:(',' operand)*
         { return n.mkList(head, rest, 1); }

operand = s:expression '(' sf1:expression ',' sf2:expression ')'  { return new n.Arg({d:s,i:sf1,b:sf2}); }
        / s:expression '(' ',' sf2:expression ')'                 { return new n.Arg({d:s,b:sf2}); }
        / s:expression '(' sf1:expression ')'                     { return new n.Arg({d:s,b:sf1}); }
        / s:expression                                            { return new n.Arg({v:s}); }

dataArgs = head:dataArg rest:(',' dataArg)*
         { return n.mkList(head, rest, 1); }

dataArg = dataConstArg
        / addrConstArg
        / floatConstArg

quotedString = "'" str:(("''"/[^'])*) "'"
             { return str.join("").replace(/\'\'/g,"'").replace(/&&/g,"&"); }


dataConstArg = d:dataDupeFactor? 'C' m:dataModifiers? v:quotedString
               { return new n.DataConstant(d,'C',m,v); }
             / d:dataDupeFactor? t:dataConstType m:dataModifiers? v:dataNomValue?
               { return new n.DataConstant(d,t,m,v); }

addrConstArg = d:dataDupeFactor? t:addrConstType m:dataModifiers? v:addrNomValue?
               { return new n.AddrConstant(d,t,m,v); }

floatConstArg = d:dataDupeFactor? t:floatConstType m:dataModifiers? v:floatNomValue?
               { return new n.DataConstant(d,t,m,v); }


dataDupeFactor = '(' d:expression ')' { return d; }
               / d:decimal_term       { return d; }

dataType = 'C' / 'X' / 'B' / 'F' / 'H' / 'E' / 'D' / 'P' / 'Z' / 'A' / 'Y' / 'S' / 'V' / 'Q'

dataConstType = 'C' / 'X' / 'B' / 'F' / 'H' / 'P'
floatConstType = 'E' / 'D'
addrConstType = 'A' / 'Y' / 'Z'/ 'S' / 'V' / 'Q'

dataModifiers = l:dataLength? s:dataScaling? e:dataExponent? { return {length:l, scale:s, exponent:e}; }

dataLength = 'L' '(' l:expression ')' { return l; }
           / 'L' l:decimal_term       { return l; }
           / 'L' '.' '(' l:expression ')' { return {bitLength:l}; }
           / 'L' '.' l:decimal_term   { return {bitLength:l}; }

dataScaling = 'S' '(' s:expression ')' { return {scale:s}; }
            / 'S' s:decimal_term       { return {scale:s}; }
dataExponent = 'E' '(' e:expression ')' { return {exponent:e}; }
             / 'E' e:decimal_term       { return {exponent:e}; }

dataNomValue = "'" dl:constList "'" { return dl; }
addrNomValue = '(' al:addrConstList ')' { return al; }
floatNomValue = "'" dl:floatConstList "'" { return dl; }

constList = head:const rest:(',' const)*
         { return n.mkList(head, rest, 1); }

addrConstList = head:addrConst rest:(',' addrConst)*
         { return n.mkList(head, rest, 1); }

floatConstList = head:floatConst rest:(',' floatConst)*
          { return n.mkList(head,rest,1); }

const = d:hexadecimal_digit+ { return d.join(''); }
      / e:expression         { return e; }

addrConst = d:digit+ { return d.join(''); }
          / e:expression { return e; }


floatConst = s:('+'/'-')? i:[0-9]+ d:('.' [0-9]*)? e:exponents?
          {
            var smult   = (s === '-') ? -1 : 1;
            var integer = (i.length)  ? i.join("")  : '0';
            var frac    = (d && d[1].length) ? d[1].join("") : '0';
            var exp     = e ? e : 1;

            return smult * parseFloat(integer + '.' + frac) * exp;
          }
        / s:('+'/'-')? i:[0-9]* d:('.' [0-9]+) e:exponents?
          {
            var smult   = (s === '-') ? -1 : 1;
            var integer = (i.length)  ? i.join("")  : '0';
            var frac    = (d && d[1].length) ? d[1].join("") : '0';
            var exp     = e ? e : 1;

            return smult * parseFloat(integer + '.' + frac) * exp;
          }

exponents = el:exponent+        { return el.reduce(function(x,y) { return x*y; }); }

exponent = 'B' p:signed_integer {  return Math.pow(2,p); }
         / 'E' p:signed_integer { return Math.pow(10,p); }
         / 'H' p:signed_integer { return Math.pow(16,p); }

signed_integer = s:('+'/'-')? i:[0-9]+
               { return parseInt(i.join(""),10) * (s === '-' ? -1 : 1); }


exprList = head:expression rest:(',' expression)*
         { return n.mkList(head, rest, 1); }

statement = '*' c:comments
            {
                return new n.Statement(null,null,[],location(),c);
            }
            / l:name __ op:('CSECT'/'DSECT') _ c:comments?
            {
              return new n.stSECT(l, op,location(),c);
            }
            / l:name __ 'EQU' __ e:expression _ c:comments?
            {
              return new n.stEQU(l,e,location(),c);
            }
            / l:name? __ 'DS' __ args:dataArgs _ c:comments?
            {
              return new n.stDS(l,args,location(),c);
            }
            / l:name? __ 'DS' __ args:dataArgs _ c:comments?
            {
              return new n.stDS(l,args,location(),c);
            }
            / l:name? __ 'DC' __ args:dataArgs _ c:comments?
            {
              return new n.stDC(l,args,location(),c);
            }
            / __ 'EXTRN' __ arg:nameList _ c:comments?
            {
              return new n.stEXTRN(arg,location(),c);
            }
            / __ 'ENTRY' __ arg:nameList _ c:comments?
            {
              return new n.stENTRY(arg,location(),c);
            }
            / __ 'USING' __ args:exprList _ c:comments?
            {
              return new n.stUSING(args,location(),c);
            }
            / __ 'SPACE' _ c:comments?
            {
              return new n.stSPACE(location(),c);
            }
            / __ 'END' _ c:comments?
            {
              return new n.stComment(c,location());
            }
            / 'END'
            {
              return new n.stComment("",location());
            }
            / __ 'LTORG' _ c:comments?
            {
              return new n.stLTORG(c,location());
            }
            / 'LTORG'
            {
              return new n.stLTORG("",location());
            }

            / l:name __ op:operation __ args:operands _ c:comments?
            {
              return new n.stOP(l,op,args,location(),c);
            }
            / l:name __ op:operation _ c:comments?
            {
              return new n.stOP(l,op,location(),c);
            }
            / _ op:operation __ args:operands _ c:comments?
            {
              return new n.stOP(null,op,args,location(),c);
            }
            / _ op:operation _ c:comments?
            {
              return new n.stOP(null,op,null,location(),c);
            }
            / _ c:comments _
            {
              return new n.stComment(c,location());
            }
            / [ \t]*  {}

name = s:symbol { return s; }

nameList = head:name rest:(',' name)*
         { return n.mkList(head, rest, 1); }

operation = msc_operation / bce_operation
          / o:ops '@#' { return {op:o, indirect:true, autoindex:true}; }
          / o:ops '@'  { return {op:o, indirect:true, autoindex:false}; }
          / o:ops '#'  { return {op:o, indirect:false, autoindex:true}; }
          / o:ops      { return {op:o, indirect:false, autoindex:false}; }

comments = c:[^\n]* { return c.join(""); }

_  = ([ \t]+)*  { }
__ = ([ \t\r])+  { }


ops = ops_5 / ops_4 / ops_3 / ops_2 / ops_1

ops_1 = 'A' / 'C' / 'D' / 'L' / 'M' / 'S' / 'N' / 'X' / 'O'
      / 'B'
ops_2 = 'PC' / 'AR' / 'AH' / 'CR' / 'CH' / 'DR' / 'LR' / 'LA' / 'LH' / 'LM'
      / 'MR' / 'MH' / 'ST' / 'SR' / 'SH' / 'TD' / 'BC' / 'NR' / 'XR' / 'OR'
      / 'SB' / 'TB' / 'TH' / 'ZB' / 'ZH' / 'AE' / 'CE' / 'DE' / 'LE' / 'ME'
      / 'SE' / 'TS'
      / 'DC' / 'DS'
      / 'BR' / 'BH' / 'BL' / 'BE' / 'BO' / 'BP' / 'BM' / 'BZ'

ops_3 = 'AHI' / 'AST' / 'CBL' / 'CHI' / 'XUL' / 'IAL' / 'IHL' / 'LCR' / 'LHI'
      / 'MHI' / 'MIH' / 'STH' / 'STM' / 'SST' / 'BAL' / 'BIX' / 'BCR' / 'BCB'
      / 'BCF' / 'BCT' / 'BVC' / 'NCT' / 'SLL' / 'SRA' / 'SRL' / 'SRR' / 'NHI'
      / 'NST' / 'XHI' / 'XST' / 'OHI' / 'OST' / 'SUM' / 'SHW' / 'TRB' / 'ZRB'
      / 'AED' / 'AER' / 'CER' / 'DED' / 'DER' / 'LED' / 'LER' / 'MVS' / 'MED'
      / 'MER' / 'SED' / 'SER' / 'STE' / 'LPS' / 'MVH' / 'SPM' / 'SSM' / 'SVC'
      / 'TSB' / 'ICR'
      / 'EQU' / 'CXD' / 'DXD' / 'COM' / 'ORG' / 'END'
      / 'NOP' / 'BHR' / 'BLR' / 'BER' / 'BNH' / 'BNL' / 'BNE' / 'BOR' / 'BPR'
      / 'BMR' / 'BNP' / 'BNM' / 'BNZ' / 'BZR' / 'BNO'

ops_4 = 'CIST' / 'LFXI' / 'MSTH' / 'BALR' / 'BCRE' / 'BCTB' / 'BVCR' / 'BCVF'
      / 'SLDL' / 'SRDA' / 'SRDL' / 'SRDR' / 'NIST' / 'XIST' / 'AEDR' / 'CVFX'
      / 'CVFL' / 'DEDR' / 'LECR' / 'LFXR' / 'LFLI' / 'LFLR' / 'MEDR' / 'SEDR'
      / 'STED' / 'ISPB' / 'SCAL' / 'SRET'
      / 'DROP' / 'ICTL' / 'ISEQ' / 'CNOP' / 'COPY'
      / 'NOPR' / 'BNHR' / 'BNLR' / 'BNER' / 'BNPR' / 'BNMR' / 'BNZR' / 'BNOR'

ops_5 = 'START' / 'CSECT' / 'DSECT' / 'ENTRY' / 'EXTRN' / 'USING'
      / 'TITLE' / 'EJECT' / 'SPACE' / 'PRINT' / 'LTORG' / 'PUNCH' / 'REPRO'

msc_operation = o:msc_ops { return {op:o}; }
bce_operation = o:bce_ops { return {op:o}; }

msc_ops = '@L' / '@A' / '@N' / '@X' / '@C'
        / '@ST' / '@LF' / '@LH' / '@BC' / '@BU' / '@CI' / '@TM'
        / '@TI' / '@LI'
        / '@STF' / '@STH' / '@BXC' / '@REC' / '@TSZ' / '@TMI' / '@LBB'
        / '@LBP' / 'LAR' / '@SFD' / '@RFD' / '@LMS' / '@SIO' / '@XAX'
        / '@SEC' / '@RBI' / '@NIX' / '@TAX' / '@TXI' / '@LXI' / '@TXA'
        / '@SAI' / '@RAI' / '@RAW' / '@RNI' / '@RNW' / '@WAT' / '@DLY'
        / '@INT' / '@STP'
        / '@CALL' / '@LBB@' / '@LBP@'

bce_ops = '#BU'
        / '#LTO' / '#RIB' / '#SIB' / '#SSC' / '#SST' / '#LBR' / '#WIX'
        / '#CMD' / '#TDS' / '#TDL' / '#RDS' / '#RDL' / '#MIN' / '#DLY'
        / '#WAT' / '#STP'
        / '#LTOI' / '#LBR@' / '#BU@' / '#CMDI' / '#TDLI' / '#MOUT'
        / '#RDLI' / '#MINC' / '#MIN@'
        / '#MOUTC' / '#MOUT@' / '#DLYI'
