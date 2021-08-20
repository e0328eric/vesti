" Vim syntax file
" Language: vesti

" Usage Instructions
" Put this file in .vim/syntax/vesti.vim
" and add in your .vimrc file the next line:
" autocmd BufRead,BufNewFile *.ves set filetype=vesti

if exists("b:current_syntax")
  finish
endif

syn region vestiBrackets       contained extend keepend matchgroup=Bold start=+\(\\\)\@<!\[+ end=+]\|$+ skip=+\\\s*$\|\(\\\)\@<!\\]+ contains=@tclCommandCluster

syn keyword vestiKeyword       docclass begenv nextgroup=vestiEnv skipwhite
syn keyword vestiKeyword       import document endenv mst mnd docstartmode
syn keyword vestiMathKeyword   mtxt etxt

" TODO(#3): $ and $! syntax has some issue
syn match   vestiFunction        "\v\\([a-zA-Z\@]+|\$|\\|#)"
syn match   vestiEnv             "[a-zA-Z_][a-zA-Z0-9_]*" contained
syn region  vestiComment         start="#" end="$" contains=vestiTodo
syn region  vestiComment         start="#\*" end="\*#" contains=vestiTodo,@Spell
syn region  vestiVerbatim        start="#-" end="-#"
syn region  vestiVerbatimInline  start="##-" end="-##"
syn region  vestiTextMath        start="\$" end="\$" contains=vestiMathKeyword,vestiFunction
syn region  vestiTextMath        start="\\(" end="\\)" contains=vestiMathKeyword,vestiFunction
syn region  vestiInlineMath      start="\$\$" end="\$\$" contains=vestiMathKeyword,vestiFunction
syn region  vestiInlineMath      start="\\\[" end="\\\]" contains=vestiMathKeyword,vestiFunction
syn match   vestiSharp           "#!"
syn match   vestiDollar          "$!"
syn keyword vestiTodo            TODO FIXME XXX contained

" numbers (including longs and complex)
let s:dec_num = '-?\d%(_?\d)*'
let s:int_suf = '%(''%(%(i|I|u|U)%(8|16|32|64)|u|U))'
let s:float_suf = '%(''%(%(f|F)%(32|64|128)?|d|D))'
let s:exp = '%([eE][+-]?'.s:dec_num.')'
exe 'syn match vestiNumber /\v<0[bB][01]%(_?[01])*%('.s:int_suf.'|'.s:float_suf.')?>/'
exe 'syn match vestiNumber /\v<0[ocC]\o%(_?\o)*%('.s:int_suf.'|'.s:float_suf.')?>/'
exe 'syn match vestiNumber /\v<0[xX]\x%(_?\x)*%('.s:int_suf.'|'.s:float_suf.')?>/'
exe 'syn match vestiNumber /\v<'.s:dec_num.'%('.s:int_suf.'|'.s:exp.'?'.s:float_suf.'?)>/'
exe 'syn match vestiNumber /\v<'.s:dec_num.'\.'.s:dec_num.s:exp.'?'.s:float_suf.'?>/'
unlet s:dec_num s:int_suf s:float_suf s:exp

syn sync match vestiSync grouphere NONE "):$"
syn sync maxlines=200
syn sync minlines=2000

command -nargs=+ HiLink hi link <args>

" The default methods for highlighting.  Can be overridden later
HiLink vestiBrackets Operator
HiLink vestiKeyword	Keyword
HiLink vestiMathKeyword	Keyword
HiLink vestiEnv Function
HiLink vestiFunction Identifier
HiLink vestiComment Comment
HiLink vestiTodo Todo
HiLink vestiNumber Number
HiLink vestiVerbatim PreProc 
HiLink vestiVerbatimInline PreProc 
hi vestiSharp ctermfg=LightBlue guifg=LightBlue
hi vestiDollar ctermfg=LightBlue guifg=LightBlue
hi vestiTextMath ctermfg=LightMagenta guifg=LightMagenta
hi vestiInlineMath ctermfg=LightMagenta guifg=LightMagenta

delcommand HiLink

let b:current_syntax = 'vesti'

