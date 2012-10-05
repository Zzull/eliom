(* Ocsigen
 * http://www.ocsigen.org
 * Copyright (C) 2011 Pierre Chambart
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(* TODO: implement with WeakMap when standardised:
   https://developer.mozilla.org/en/JavaScript/Reference/Global_Objects/WeakMap

class type ['a,'b] weakMap = object
  method get : 'a -> 'b Js.optdef Js.meth
  method set : 'a -> 'b -> unit Js.meth
  method has : 'a -> bool Js.t Js.meth
end

let weakMap : ('a,'b) weakMap Js.t Js.constr = Js.Unsafe.variable "window.WeakMap"

let map : (Obj.t,Obj.t) weakMap Js.t = jsnew weakMap ()

let get_obj_copy map o = Js.Optdef.to_option ( map##get(o) )
let set_obj_copy map o c = map##set(o,c)
*)

class type obj_with_copy = object
  method camlObjCopy : Obj.t Js.optdef Js.prop
end

let get_obj_copy o =
  let v : obj_with_copy Js.t = Obj.obj o in
  Js.Optdef.to_option ( v##camlObjCopy )

let set_obj_copy o c =
  let v : obj_with_copy Js.t = Obj.obj o in
  v##camlObjCopy <- Js.def c;

module Mark : sig
  type t
end
=
struct
  type t = string
end

(* XXX must be the same as in Ocsigen_wrap *)
type unwrap_id = int

let id_of_int x = x

type unwrapper =
    { id : unwrap_id;
      mutable umark : Mark.t; }

let unwrap_table : (Obj.t -> Obj.t) Js.js_array Js.t = jsnew Js.array_empty ()
(* table containing all the unwrapping functions referenced by their id *)

type occurrence = {
  parent : Obj.t;
  field : int
}
type occurrences = {
  instance_id : int;
  value : Obj.t;
  mutable occurrences : occurrence list
}
type all_occurrences = occurrences list
let occurrences_table : all_occurrences Js.js_array Js.t = jsnew Js.array_empty ()

let remaining_values_for_late_unwrapping () =
  let rec aux sofar n =
    if n = occurrences_table##length then
      List.rev sofar
    else
      if Js.Optdef.test (Js.array_get occurrences_table n) then
        aux (n :: sofar) (succ n)
      else aux sofar (succ n)
  in aux [] 0

let register_unwrapper id f =
  if Js.Optdef.test (Js.array_get unwrap_table id) then
    failwith (Printf.sprintf ">> the unwrapper id %i is already registered" id);
  let f x = Obj.repr (f (Obj.obj x)) in
  (* Store unwrapper *)
  Js.array_set unwrap_table id f;
  (* Do late unwrapping *)
  Js.Optdef.iter (Js.array_get occurrences_table id)
    (fun all_occurrences ->
      if Eliom_config.get_tracing () then
        Firebug.console##log(Printf.ksprintf Js.string "Late unwrapping for %i in %d instances"
                               id (List.length all_occurrences));
      List.iter
        (fun { value; occurrences } ->
          let value' = f value in
          List.iter
            (fun { parent; field } ->
              Js.Unsafe.set parent field value')
            occurrences)
        all_occurrences;
      Js.Unsafe.delete occurrences_table id)

let apply_unwrapper unwrapper v =
  Js.Optdef.case (Js.array_get unwrap_table unwrapper.id)
    (fun () -> None) (* Use late unwrapping! *)
    (fun f -> Some (f v))

(* Register the occurrence of a [value] inside another value [parent]
   at position [field].
*)
let register_late_occurrence parent field value unwrap_id instance_id =
  if Eliom_config.get_tracing () then
    Firebug.console##log_3
      (Printf.ksprintf Js.string ">> register_late_occurrence unwrapper:%d instance:%d at"
         unwrap_id instance_id, parent, Printf.ksprintf Js.string "[%d]" field);
  let parent = Obj.repr parent in
  let value = Obj.repr value in
  let all_occurrences =
    Js.Optdef.get
      (Js.array_get occurrences_table unwrap_id)
      (fun () -> [])
  in
  let all_occurrences' =
    try
      let occurrences =
        List.find (fun occurrences -> occurrences.instance_id = instance_id)
          all_occurrences
      in
      occurrences.occurrences <- { parent; field } :: occurrences.occurrences;
      all_occurrences
    with Not_found ->
      { instance_id; value; occurrences = [ {parent; field} ] } :: all_occurrences
  in
  Js.array_set occurrences_table unwrap_id all_occurrences'
    
let late_unwrap_value unwrap_id predicate new_value =
  let all_occurrences =
    Js.Optdef.get
      (Js.array_get occurrences_table unwrap_id)
      (fun () -> [])
  in
  let current_occurrences, all_occurrences' =
    List.partition (fun { value } -> predicate (Obj.obj value)) all_occurrences
  in
  if Eliom_config.get_tracing () then
    Firebug.console##log
      (Printf.ksprintf Js.string ">> set_late_unwrap unwrapper:%d for %d cases"
         unwrap_id (List.length current_occurrences));
  List.iter
    (fun { occurrences } ->
      List.iter
        (fun { parent; field } ->
          Js.Unsafe.set parent field new_value)
        occurrences)
    current_occurrences;
  if all_occurrences' = [] then
    Js.Unsafe.delete occurrences_table unwrap_id
  else
    Js.array_set occurrences_table unwrap_id all_occurrences'

external raw_unmarshal_and_unwrap
  : (unwrapper -> _ -> _ option) ->
    (_ -> int -> _ -> int -> int -> unit) ->
      string -> int -> _
        = "caml_unwrap_value_from_string"

let unwrap s i =
  raw_unmarshal_and_unwrap
    apply_unwrapper register_late_occurrence s i

let unwrap_js_var s =
  unwrap (Js.to_bytestring (Js.Unsafe.variable s)) 0

