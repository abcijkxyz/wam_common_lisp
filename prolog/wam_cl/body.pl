/*******************************************************************
 *
 * A Common Lisp compiler/interpretor, written in Prolog
 *
 * (lisp_compiler.pl)
 *
 *
 * Douglas'' Notes:
 *
 * (c) Douglas Miles, 2017
 *
 * The program is a *HUGE* common-lisp compiler/interpreter. It is written for YAP/SWI-Prolog .
 *
 * Changes since 2001:
 *
 *
 *******************************************************************/
:- module(body, []).
:- set_module(class(library)).
:- include('header.pro').
:- set_module(class(library)).
:- ensure_loaded(utils_for_swi).

must_compile_closure_body(Ctx,Env,Result,Function, Body):-
  must_compile_body(Ctx,Env,Result,Function, Body0),
  body_cleanup_keep_debug_vars(Ctx,Body0,Body).


% compile_body(Ctx,Env,Result,Function, Body).
% Expands a Lisp-like function body into its Prolog equivalent

must_compile_body(Ctx,Env,Result,Function, Body):-
  notrace((maybe_debug_var('_rCtx',Ctx),
  maybe_debug_var('_rEnv',Env),
  maybe_debug_var('_rResult',Result),
  maybe_debug_var('_rForms',Function),
  maybe_debug_var('_rBody',Body))),
  must_or_rtrace(compile_body(Ctx,Env,Result,Function, Body)),
  % nb_current('$compiler_PreviousResult',THE),setarg(1,THE,Result),
  !.

make_holder('$hldr'([])).
nb_set_last_tail(HT,Last):- HT=[_|T], ((compound(T),functor(T,_,2)) -> nb_set_last_tail(T,Last);  nb_setarg(2,HT,Last)).
nb_holder_append(Obj,Value):- is_list(Obj),!,nb_set_last_tail(Obj,[Value]). 
nb_holder_append(Obj,Value):- functor(Obj,_,A),arg(A,Obj,E),
  (E==[] -> nb_setarg(A,Obj,[Value]) ;
   (is_list(E)-> nb_set_last_tail(E,[Value]) ; nb_setarg(A,Obj,[E,Value]))).
nb_holder_setval(Obj,Value):- is_list(Obj),!,nb_setarg(1,Obj,Value),nb_setarg(2,Obj,[]).
nb_holder_setval(Obj,Value):- functor(Obj,_,A),nb_setarg(A,Obj,Value).
nb_holder_value(Obj,Value):- is_list(Obj),!,([Value]=Obj->true;Value=Obj).
nb_holder_value(Obj,Value):- functor(Obj,_,A),arg(A,Obj,Value). 

make_restartable_block(Place,CodeWithPlace,LispCode):-
     gensym(restartable_block,GenBlock),gensym(restartable_loop,GenLoop),
     LispCode = [ block, GenBlock,
                    [ tagbody,GenLoop,
                      [ restart_bind,[[ store_value,[ lambda,[u_object],[setf, Place, u_object],[go, GenLoop]]]],
                        [ return_from,GenBlock,[progn|CodeWithPlace] ]]]].


:- dynamic(compiler_macro_left_right/3).
:- discontiguous(compiler_macro_left_right/3).
/*

(defmacro while (cond &rest forms)
  (let ((start (gensym)))
  `(tagbody ,start 
     (when ,cond (progn ,@forms) (go ,start)))))
       



(let ((x 10)) (while (> (decf x) 1) (print x )))

(LET ((x 10 ))(while (> (DECF x )1 )(PRINT x )(SETQ x (1- x ))))

(LET ((x 10 ))(while (> (DECF x )1 )(PRINT x )(SETQ x (1- x ))))


*/
compiler_macro_left_right(u_while,[Cond|Forms], 
  [tagbody,Start,[when,Cond,[progn|Forms],[go,Start]]]) :- gensym('while',Start).
compiler_macro_left_right(while,[Cond|Forms], 
  [tagbody,Start,[when,Cond,[progn|Forms],[go,Start]]]) :- gensym('while',Start).


% PROG
/*(defmacro prog (inits &rest forms)
  `(block nil
    (let ,inits
      (tagbody ,@forms))))
*/
compiler_macro_left_right(prog,[Vars|Forms], [block,[],[let,Vars,[tagbody|Forms]]]).
% (defmacro unless (test-form &rest forms) `(if (not ,test-form) (progn ,@forms)))
compiler_macro_left_right(unless,[Test|IfFalse] , [if, Test, [], [progn|IfFalse]]).
% (defmacro when (test-form &rest forms) `(if ,test-form (progn ,@forms)))
compiler_macro_left_right( when,[Test|IfTrue]  , [if, Test, [progn|IfTrue], []]).

% IF/1
compiler_macro_left_right(if,[Test, IfTrue], [if, Test, IfTrue ,[]]).

% AND
compiler_macro_left_right(and,[], []).
compiler_macro_left_right(and,[Form1], Form1).
compiler_macro_left_right(and,[Form1,Form2], [if,Form1,Form2]).
compiler_macro_left_right(and,[Form1|Rest], [and,Form1,[and|Rest]]).


:- discontiguous(compile_body/5).

% Prolog vars
compile_body(_Ctx,_Env,Result,Var, true):- is_ftVar(Var), !, Result = Var.
compile_body(Ctx,Env,Result,Var, Code):- is_ftVar(Var), !, % NEVER SEEN
  debug_var("EVAL",Var),
  must_compile_body(Ctx,Env,Result,[eval,Var], Code).

% Lazy Reader
compile_body(Ctx,Env,Result, 's'(Str),  Body):-
  parse_sexpr_untyped(string(Str),Expression),!,
  must_compile_body(Ctx,Env,Result, Expression,  Body).

% Compiler Plugin
compile_body(Ctx,Env,Result,InstrS,Code):-
  shared_lisp_compiler:plugin_expand_function_body(Ctx,Env,Result,InstrS,Code),!.

% PROGN
compile_body(Ctx,Env,Result,[progn|Forms], Body):- !, must_compile_progn(Ctx,Env,Result,Forms,[],Body).

% SOURCE TRANSFORMATIONS
compile_body(Ctx,Env,Result,[M|MACROLEFT], Code):- atom(M),
  term_variables([M|MACROLEFT],VarsS),
  compiler_macro_left_right(MS,MACROLEFT,MACRORIGHT),
  same_symbol(M,MS),
  term_variables(MACRORIGHT,VarsE),
  VarsE==VarsS,!,
  must_compile_body(Ctx,Env,Result,MACRORIGHT, Code).

% SELF EVALUATING OBJECTS
compile_body(_Cx,_Ev, [],[],true):- !.
compile_body(_Cx,_Ev, [],nil,true):- !.
compile_body(_Cx,_Ev,SelfEval,SelfEval,true):- notrace(is_self_evaluationing_object(SelfEval)),!.

% numbers
compile_body(_Ctx,_Env,Value,Atom,true):- atom(Atom),atom_number_exta(Atom,Value),!.
% string
compile_body(_Ctx,_Env,Atom,'$STRING'(Atom),true).
% #S
compile_body(_Ctx,_Env,Result,'$S'([Type|Args]),create_struct([Type|Args],Result)).

atom_number_exta(Atom,Value):- on_x_rtrace(atom_number(Atom,Value)).
atom_number_exta(Atom,Value):- atom_concat_or_rtrace('-.',R,Atom),atom_concat_or_rtrace('-0.',R,NAtom),!,atom_number(NAtom,Value).
atom_number_exta(Atom,Value):- atom_concat_or_rtrace('.',R,Atom),atom_concat_or_rtrace('0.',R,NAtom),!,atom_number(NAtom,Value).


% symbols
compile_body(Ctx,Env,Value,Atom, Body):- atom(Atom),!,
  must_or_rtrace(compile_symbol_getter(Ctx,Env,Value, Atom, Body)).

% QUOTE
compile_body(_Cx,_Ev,Item,[quote, Item],  true):- !.

% COMMENTS
is_comment([COMMENT,String|_],String):- atom(COMMENT),!,atom_concat_or_rtrace('$COMMENT',_,COMMENT).
is_comment(COMMENTP,String):- compound(COMMENTP),!,COMMENTP=..[COMMENT,String|_],!,atom_concat_or_rtrace('$COMMENT',_,COMMENT).

compile_body(_Ctx,_Env,[],COMMENT,true):- is_comment(COMMENT,_),!.


% OR
compiler_macro_left_right(or,[], []).
compiler_macro_left_right(or,[Form1], Form1).
% OR-0
compile_body(_Ctx,_Env,[],[or], true).
% OR-1
compile_body(Ctx,Env,Result,[or,Form], Body):- must_compile_body(Ctx,Env,Result,Form, Body).
% OR-2+
compile_body(Ctx,Env,Result,[or,Form1|Form2],Code):- Form2\=[_],Form2\=[or|_], !, 
  compile_body(Ctx,Env,Result,[or,Form1,[or|Form2]],Code).

% OR-2 needs to use body compiler below
compile_body(Ctx,Env,Result,[or,Form1,Form2],Code):- !,
   must_compile_body(Ctx,Env,Result1,Form1, Body1),
   must_compile_body(Ctx,Env,Result2,Form2, Body2),
   debug_var("FORM1_Res",Result1),
        Code = (	Body1,
			( Result1 \== []
				-> 	Result = Result1
				;  	(Body2, Result = Result2))).

% compiler_macro_left_right(or,[Form1,Form2,Form3|Rest], [or,Form1,[or,Form2,[or,Form3,[or|Rest]]]]).



% PROG1
compile_body(Ctx,Env,Result,[prog1,Form1|FormS],Code):- !,
   must_compile_body(Ctx,Env,Result,Form1, Body1),
   must_compile_progn(Ctx,Env,_ResultS,FormS,Result,Body2),
   Code = (Body1, Body2).

% PROG2
compile_body(Ctx,Env,Result,[prog2,Form1,Form2|FormS],Code):- !,
   must_compile_body(Ctx,Env,_Result1,Form1, Body1),
   must_compile_body(Ctx,Env,Result,Form2, Body2),
   must_compile_progn(Ctx,Env,_ResultS,FormS,Result,BodyS),
   Code = (Body1, Body2, BodyS).

% `, Backquoted commas
compile_body(_Cx,Env,Result,['$BQ',Form], Code):-!,compile_bq(Env,Result,Form,Code).
compile_body(_Cx,Env,Result,['`',Form], Code):-!,compile_bq(Env,Result,Form,Code).

% #+
compile_body(Ctx,Env,Result,[OP,Flag,Form|MORE], Code):- same_symbol(OP,'#+'),!, 
   must_or_rtrace(( symbol_value(xx_features_xx,FEATURES),
          ( member(Flag,FEATURES) -> must_compile_body(Ctx,Env,Result,Form, Code) ; compile_body(Ctx,Env,Result,MORE, Code)))).
  
% #-
compile_body(Ctx,Env,Result,[OP,Flag,Form|MORE], Code):- same_symbol(OP,'#-'),!,
   must_or_rtrace(( symbol_value(xx_features_xx,FEATURES),
          ( \+ member(Flag,FEATURES) -> must_compile_body(Ctx,Env,Result,Form, Code) ; 
             compile_body(Ctx,Env,Result,MORE, Code)))).

% EVAL-WHEN
compile_body(Ctx,Env,Result,[OP,Flags|Forms], Code):-  same_symbol(OP,'eval-when'), !,
 must_or_rtrace(((member(X,Flags),is_when(X) )
  -> must_compile_body(Ctx,Env,Result,[progn,Forms], Code) ; Code = true)).


compile_body(Ctx,Env,Result, Body, Code):- 
   compile_decls(Ctx,Env,Result, Body, Code),!.


% EVAL
compile_body(Ctx,Env,Result,['eval',Form1],
  (Body1,cl_eval(Result1,Result))):- !,
   must_compile_body(Ctx,Env,Result1,Form1, Body1).

% COMPILE-TOPLEVEL LOAD-TOPLEVEL EXECUTE
is_when(X):- dbmsg(warn(free_pass(is_when(X)))).


must_compile_test_body(Ctx,Env,TestResult,Test,TestBody,TestResultBody):-
  must_or_rtrace(compile_test_body(Ctx,Env,TestResult,Test,TestBody,TestResultBody)).

% IF (null ...)
compile_test_body(Ctx,Env,TestResult,[null,Test],TestBody,TestResultBody):-
   debug_var("TestNullResult",TestResult),
   must_compile_body(Ctx,Env,TestResult,Test,  TestBody),
   TestResultBody = (TestResult == []).

compile_test_body(Ctx,Env,TestResult,[=,V1,V2],(TestBody1,TestBody2),TestResultBody):-
   debug_var("TestEqualResult",TestResult),
   must_compile_body(Ctx,Env,TestResult1,V1,  TestBody1),
   must_compile_body(Ctx,Env,TestResult2,V2,  TestBody2),
   TestResultBody = (TestResult1 =:= TestResult2).


% IF TEST
compile_test_body(Ctx,Env,TestResult,Test,TestBody,TestResultBody):-
   debug_var("GTestResult",TestResult),
   must_compile_body(Ctx,Env,TestResult,Test,  TestBody),
   TestResultBody = (TestResult \== []).



% IF-3
compile_body(Ctx,Env,Result,[if, Test, IfTrue, IfFalse], Body):-
	!,
   debug_var("IFTEST",TestResult),
   debug_var("TrueResult",TrueResult),
   debug_var("FalseResult",FalseResult),

   compile_test_body(Ctx,Env,TestResult,Test,TestBody,TestResultBody),
   must_compile_body(Ctx,Env,TrueResult,IfTrue, TrueBody),
   must_compile_body(Ctx,Env,FalseResult,IfFalse, FalseBody),

        Body = (	TestBody,
			( TestResultBody
				-> 	TrueBody,
					Result      = TrueResult
				;  	FalseBody,
					Result      = FalseResult	) ).

% DOLIST
compile_body(Ctx,Env,Result,['dolist',[Var,List]|FormS], Code):- !,
    must_compile_body(Ctx,Env,ResultL,List,ListBody),
    must_compile_body(Ctx,Env2,Result,[progn,FormS], Body),
    debug_var('BV',BV),debug_var('Env2',Env2),debug_var('Ele',X),debug_var('List',ResultL),
    Code = (ListBody,
      (( BV = bv(Var,X),Env2 = [BV|Env])),
        forall(member(X,ResultL),
          (nb_setarg(2,BV,X),
            Body))).


%   (case A ((x...) B C...)...)  -->
%   (let ((@ A)) (cond ((memv @ '(x...)) B C...)...))
compile_body(Ctx,Env,Result,[CASE,VarForm|Clauses], Body):-  member(CASE,[case,ecase,ccase]),
  compile_body(Ctx,Env,Key,VarForm,VarBody),
   debug_var('Key',Key),
   make_holder(SOf),    
   cases_to_conds(SOf,Key,Clauses,Conds),
   nb_holder_value(SOf,Values),
   (CASE\==case -> (Values==t -> true ; nb_set_last_tail(Conds,[[t,['type_error',Key,[quote,[member|Values]]]]])) ; true),
   wdmsg(CASE:-Clauses),wdmsg(conds:-Conds),
   (CASE==ccase -> (make_restartable_block(Key,[cond|Conds],LispCode),compile_body(Ctx,Env,Result,LispCode, Body0)) ;
     compile_body(Ctx,Env,Result,[cond|Conds], Body0)),
   Body = (VarBody,Body0).

cases_to_conds(_SOf,_,[],[]) :- !.
cases_to_conds(SOf,_,[[otherwise|Tail]],  [[t,[progn|Tail]]]):- nb_holder_setval(SOf,t).
cases_to_conds(SOf,_,[[t|Tail]],  [[t,[progn|Tail]]]):- nb_holder_setval(SOf,t).
cases_to_conds(SOf,V,[[One|Tail]|Tail2], [[['eq',V,[quote,Realy1]],[progn|Tail]]|X]) :- is_list(One),One=[Realy1],nb_holder_append(SOf,Realy1),
    cases_to_conds(SOf,V,Tail2,X).
cases_to_conds(SOf,V,[[Set|Tail]|Tail2], [[['sys_memq',V,[quote,Set]],[progn|Tail]]|X]) :- \+ atomic(Set),nb_holder_append(SOf,[or|Set]),
    cases_to_conds(SOf,V,Tail2,X).
cases_to_conds(SOf,V,[[Item|Tail]|Tail2], [[['eq',V,[quote,Item]],[progn|Tail]]|X]) :- nb_holder_append(SOf,Item),
   cases_to_conds(SOf,V,Tail2,X).

% Macro TYPECASE, CTYPECASE, ETYPECASE
%   (typecase A ((x...) B C...)...)  -->
%   (let ((@ A)) (cond ((memv @ '(x...)) B C...)...))
compile_body(Ctx,Env,Result,[CASE,VarForm|Clauses], Body):-  member(CASE,[typecase,etypecase,ctypecase]),
  compile_body(Ctx,Env,Key,VarForm,VarBody),
   debug_var('Key',Key),
   make_holder(SOf),    
   typecases_to_conds(SOf,Key,Clauses,Conds),
   nb_holder_value(SOf,Values),
   (CASE\==typecase -> (Values==t -> true ; nb_set_last_tail(Conds,[[t,['type_error',Key,[quote,[or|Values]]]]])) ; true),
   wdmsg(CASE:-Clauses),wdmsg(conds:-Conds),
   (CASE==ctypecase -> (make_restartable_block(Key,[cond|Conds],LispCode),compile_body(Ctx,Env,Result,LispCode, Body0)) ;
     compile_body(Ctx,Env,Result,[cond|Conds], Body0)),
   Body = (VarBody,Body0).

typecases_to_conds(_SOf,_,[],[]) :- !.
typecases_to_conds(SOf,_,[[otherwise|Tail]],  [[t,[progn|Tail]]]):- nb_holder_setval(SOf,t).
typecases_to_conds(SOf,_,[[t|Tail]],  [[t,[progn|Tail]]]):- nb_holder_setval(SOf,t).
typecases_to_conds(SOf,V,[[One|Tail]|Tail2], [[['typep',V,[quote,Realy1]],[progn|Tail]]|X]) :- is_list(One),One=[Realy1],nb_holder_append(SOf,Realy1),
    typecases_to_conds(SOf,V,Tail2,X).
typecases_to_conds(SOf,V,[[Set|Tail]|Tail2], [[['typep',V,[quote,[or|Set]]],[progn|Tail]]|X]) :- \+ atomic(Set),nb_holder_append(SOf,[or|Set]),
    typecases_to_conds(SOf,V,Tail2,X).
typecases_to_conds(SOf,V,[[Item|Tail]|Tail2], [[['typep',V,[quote,Item]],[progn|Tail]]|X]) :- nb_holder_append(SOf,Item),
   typecases_to_conds(SOf,V,Tail2,X).


% COND
compile_body(_Cx,_Ev,[],[cond ], true):- !.
compile_body(_Cx,_Ev,[],[cond ,[]], true):- !.
compile_body(Ctx,Env,Result,[cond, List |Clauses], Body):- 
  must_or_rtrace((
        [Test|ResultForms] = List,
        debug_var("CONDTESTA",TestResult),
        debug_var("ResultFormsResult",ResultFormsResult),
        debug_var("ClausesResult",ClausesResult),
        debug_var("CondAResult",Result))),
   Result  = ClausesResult,
   %Result  = ResultFormsResult,
   freeze(Result,var(Result)),
   must_compile_test_body(Ctx,Env,TestResult,Test,TestBody,TestResultBody),
   must_compile_progn(Ctx,Env,ResultFormsResult,ResultForms, TestResult, ResultFormsBody),
   must_compile_body(Ctx,Env,ClausesResult,[cond| Clauses],  ClausesBody),
   Body = (((TestBody, TestResultBody) -> 
      ( ResultFormsBody,Result  = ResultFormsResult); 
      ( ClausesBody))),!.
   

compile_body(Ctx,Env,Result,[cond, List |Clauses], Body):- !,
  must_or_rtrace((
        [Test|ResultForms] = List,
        debug_var("CONDTESTB",TestResult),
        debug_var("ResultFormsResult",ResultFormsResult),
        debug_var("ClausesResult",ClausesResult),
        debug_var("CondBResult",Result))),
	must_compile_body(Ctx,Env,TestResult,Test,TestBody),
	must_compile_progn(Ctx,Env,ResultFormsResult,ResultForms, TestResult, ResultFormsBody),
	must_compile_body(Ctx,Env,ClausesResult,[cond| Clauses],  ClausesBody),
	Body = (	 
			(( (TestBody, TestResult \==[])
				->(	ResultFormsBody,
					Result      = ResultFormsResult)
				;	(ClausesBody,
					Result      = ClausesResult )	))).



% CONS inine
compile_body(Ctx,Env,Result,[cons, IN1,IN2], Body):- \+ current_prolog_flag(lisp_inline,false),
	!,
        must_compile_body(Ctx,Env,MID1,IN1,  ValueBody1),
        must_compile_body(Ctx,Env,MID2,IN2,  ValueBody2),
        Body = (ValueBody1,ValueBody2,Result=[MID1|MID2]).


p_or_s([F|Args],F0,Args0):-!,F0=F,Args0=Args.
p_or_s(POrSTerm,F,Args):- POrSTerm=..[F|Args].

% (function (lambda ... ))
compile_body(Ctx,_Env,Result,POrSTerm, Body):- p_or_s(POrSTerm,function,[[lambda,LambdaArgs| LambdaBody]]),
      !,
      must_compile_closure_body(Ctx,ClosureEnvironment,ClosureResult,[progn|LambdaBody],  ClosureBody),
      debug_var('LArgs',LambdaArgs),
      debug_var('LResult',ClosureResult),
      debug_var('LEnv',ClosureEnvironment),
   debug_var('Function',Result),
   Result = closure(ClosureEnvironment,ClosureResult,LambdaArgs,ClosureBody),
   Body = true.

% (lambda ...)
compile_body(Ctx,Env,Result,[lambda,LambdaArgs|LambdaBody], Body):-
	!,
	must_compile_closure_body(Ctx,ClosureEnvironment,ClosureResult,[progn|LambdaBody],  ClosureBody),
   debug_var('LArgs',LambdaArgs),
   debug_var('LResult',ClosureResult),
   debug_var('Lambda',Result),
   debug_var('ClosureEnvironment',ClosureEnvironment),
   Body =
     (Result = closure([ClosureEnvironment|Env],ClosureResult,LambdaArgs,ClosureBody)).
   

% (function ?? )
compile_body(_Cx,_Ev,function(Function),POrSTerm, true):- p_or_s(POrSTerm,function,[Function]).

% (closure ...)
compile_body(_Ctx,_Env,Result,POrSTerm,Body):- 
   p_or_s(POrSTerm,closure,[ClosureEnvironment,ClosureResult,LambdaArgs,ClosureBody]),
   debug_var('Closure',Result),
   debug_var('ClosureResult',ClosureResult),
   Body =
     (Result = closure(ClosureEnvironment,ClosureResult,LambdaArgs,ClosureBody)).
        
	

% (compile ...)
compile_body(Ctx,Env,Result,[compile|Forms], Body):- !,
   must_compile_closure_body(Ctx,CompileEnvironment,CompileResult,[progn|Forms],  CompileBody),
   
   debug_var('LResult',CompileResult),
   debug_var('CompileEnvironment',CompileEnvironment),
   Result = closure([CompileEnvironment|Env],CompileResult,[],CompileBody),
   Body = true.



% PROGV    % ( progv ' ( a ) ` ( , ( + 1 1 ) ) a ) => 2
compile_body(Ctx,Env,Result,[progv,VarsForm,ValuesForm|FormS],Code):- !,
   must_compile_body(Ctx,Env,VarsRs,VarsForm,Body1),
   must_compile_body(Ctx,Env,ValuesRs,ValuesForm,Body2),
   must_compile_progn(Ctx,Env,Result,FormS,[],BodyS),
   Code = (Body1, Body2 , maplist(bind_dynamic_value(Env),VarsRs,ValuesRs), BodyS).

normalize_let([],[]).
normalize_let([Decl|NewBindingsIn],[Norm|NewBindings]):-
  must_or_rtrace(normalize_let1(Decl,Norm)),!,
  normalize_let(NewBindingsIn,NewBindings).


normalize_let1([bind, Variable, Form],[bind, Variable, Form]).
normalize_let1([Variable, Form],[bind, Variable, Form]).
normalize_let1( Variable,[bind, Variable, []]).

compile_body(_Ctx,_Env,_Result,[OP|R], _Body):- var(OP),!,trace_or_throw(c_b([OP|R])).

% LET
compile_body(Ctx,Env,Result,[OP, NewBindingsIn| BodyForms], Body):- (var(OP)-> throw(var(OP)) ; OP==let),!,
 must_or_rtrace(is_list(NewBindingsIn)),!,
 must_or_rtrace(compile_let(Ctx,Env,Result,[let, NewBindingsIn| BodyForms], Body)).


compile_let(Ctx,Env,Result,[let, []| BodyForms], Body):- !, compile_forms(Ctx,Env,Result, BodyForms, Body).
compile_let(Ctx,Env,Result,[let, NewBindingsIn| BodyForms], Body):- !,
     must_or_rtrace(normalize_let(NewBindingsIn,NewBindings)),!,
	zip_with(Variables, ValueForms, [Variable, Form, [bind, Variable, Form]]^true, NewBindings),
	must_or_rtrace(expand_arguments(Ctx,Env,'funcall',1,ValueForms, ValueBody, Values)),
        freeze(Var,ignore((var(Val),debug_var('_Init',Var,Val)))),
        freeze(Var,ignore(((var(Val),add_tracked_var(Ctx,Var,Val))))),
        zip_with(Variables, Values, [Var, Val, bv(Var,Val)]^true,Bindings),
        add_alphas(Ctx,Variables),
        debug_var("LETENV",BindingsEnvironment),
        ignore((member(VarN,[Variable,Var]),atom(VarN),var(Val),debug_var([VarN,'_Let'],Val))),        
	must_compile_progn(Ctx,BindingsEnvironment,Result,BodyForms, [], BodyFormsBody),
         Body = ( ValueBody,BindingsEnvironment=[Bindings|Env], BodyFormsBody ).

% LET*
compile_body(Ctx,Env,Result,[OP, []| BodyForms], Body):- same_symbol(OP,'let*'), !, must_compile_body(Ctx,Env,Result,[progn| BodyForms], Body).
compile_body(Ctx,Env,Result,[OP, [Binding1|NewBindings]| BodyForms], Body):- same_symbol(OP,'let*'),
   must_or_rtrace(compile_let(Ctx,Env,Result,['let', [Binding1],[progn, [OP, NewBindings| BodyForms]]], Body)).

% VALUES (r1 . rest )
compile_body(Ctx,Env,Result,['values',R1|EvalList], (ArgBody,Body)):-!,
    expand_arguments(Ctx,Env,funcall,0,[R1|EvalList], ArgBody, [Result|Results]),
    Body = nb_setval('$mv_return',[Result|Results]).
compile_body(_Ctx,_Env,[],['values'], nb_setval('$mv_return',[])):-!.

:- nb_setval('$mv_return',[]).

% Macro MULTIPLE-VALUE-BIND
compile_body(Ctx,Env,Result,[OP,Vars,Eval1|ProgN], Body):- same_symbol(OP,'multiple-value-bind'),
  must_compile_body(Ctx,Env,Result,[let,Vars,[progn,Eval1,['setqvalues',Vars]|ProgN]],Body).

% Macro MULTIPLE-VALUE-LIST
compile_body(Ctx,Env,Result,[OP,Eval1], (Body,nb_current('$mv_return',Result))):-
  same_symbol(OP,'multiple-value-list'),
  debug_var('MV_RETURN',Result),
  debug_var('IgnoredRet',IResult),
  must_compile_body(Ctx,Env,IResult,Eval1,Body).

% Macro MULTIPLE-VALUE-CALL
compile_body(Ctx,Env,Result,[OP,Function|Progn], Body):-
  same_symbol(OP,'multiple-value-call'),
  must_compile_body(Ctx,Env,Result,[progn,[progn|Progn],['apply',Function,['returnvalues']]],Body).

% synthetic RETURN-VALUES -> values
compile_body(_Ctx,_Env,Values,['returnvalues'], nb_current('$mv_return',Values)).

% synthetic SETQ-VALUES (vars*)
compile_body(_Ctx,Env,[],['setqvalues',Vars], setq_values(Env,Vars)):-!.


setq_values(Env,Vars):- nb_current('$mv_return',Values),setq_values(Env,Vars,Values).
setq_values(_Env,_,[]):-!.
setq_values(_Env,[],_):-!.
setq_values(Env,[Var|Vars],[Val|Values]):-
   set_symbol_value(Env,Var,Val),
   setq_values(Env,Vars,Values).

set_symbol_value(Var,Val):-
  env_current(Env),
  set_symbol_value(Env,Var,Val).

%   zip_with(Xs, Ys, Pred, Zs)
%   is true if Pred(X, Y, Z) is true for all X, Y, Z.

zip_with([], [], _, []).
zip_with([X|Xs], [Y|Ys], Pred, [Z|Zs]):-
	lpa_apply(Pred, [X, Y, Z]),
	zip_with(Xs, Ys, Pred, Zs).




binop_identity(+,0).
binop_identity(u_c43,0).
binop_identity(-,0).
binop_identity(*,1).
binop_identity((/),1).

% BinOP-0
compiler_macro_left_right(BinOP,L, Identity):- binop_identity(BinOP,Identity),L==[].
% BinOP-1
compiler_macro_left_right(BinOP,[Form1|NoMore], [BinOP,Identity,Form1]):- NoMore==[], binop_identity(BinOP,Identity).
% BinOP-3+
compile_body(Ctx,Env,Result,[BinOP,Form1,Form2,Form3|FormS],Code):- binop_identity(BinOP,_Identity),
  compile_body(Ctx,Env,Result1,[BinOP,Form1,Form2],Code1),
  compile_body(Ctx,Env,Result,[BinOP,Result1,Form3|FormS],Code2),
  Code = (Code1,Code2).


% BinMacro-0
compiler_macro_left_right(BinOP,L, Identity):- binary_macro(BinOP,Identity),L==[].
% BinMacro-1
compiler_macro_left_right(BinOP,[Form1|NoMore], [BinOP,Identity,Form1]):- NoMore==[], binary_macro(BinOP,Identity).
% BinMacro-3+
compile_body(Ctx,Env,Result,[BinOP,Form1|Form2],Code):- binary_macro(BinOP,_),
  Form2\=[_],Form2\=[BinOP|_], !, 
  compile_body(Ctx,Env,Result1,Form1,Code1),
  compile_body(Ctx,Env,Result2,[BinOP|Form2],Code2),
  compile_body(Ctx,Env,Result,[BinOP,Result1,Result2],Code3),
  Code = (Code1,Code2,Code3).



% EXT::XOR
binary_macro(ext_xor,[]).
compile_body(Ctx,Env,Result,[ext_xor,Form1,Form2],Code):-
  compile_body(Ctx,Env,Result1,Form1,Code1),
  compile_body(Ctx,Env,Result2,Form2,Code2),
  Code3 = (((Result1 \==[]) -> (Result2 ==[]) ; (Result2 \==[])) -> Result=t;Result=[]),
  Code = (Code1,Code2,Code3).




compile_body(Ctx,Env,Result,BodyForms, Body):- atom(BodyForms),!,
   must_or_rtrace(compile_assigns(Ctx,Env,Result,BodyForms, Body)),!.

% SETQ - PSET
compile_body(Ctx,Env,Result,BodyForms, Body):- compile_assigns(Ctx,Env,Result,BodyForms, Body),!.

compile_body(Ctx,Env,Result,BodyForms, Body):- must_or_rtrace(compile_funop(Ctx,Env,Result,BodyForms, Body)),!.


:- fixup_exports.



