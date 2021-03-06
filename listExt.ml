(*
  Atari Jaguar Removers' Linker
  Copyright (C) 2014-2017 Seb/The Removers (SebRmv@jagware.org)

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)

let init n f =
  let rec aux i = if i < n then f i :: aux (i + 1) else [] in
  aux 0

let rec choose f = function
  | [] -> []
  | x :: xs -> (
      match f x with None -> choose f xs | Some y -> y :: choose f xs )

let rec concat_map f = function [] -> [] | x :: xs -> f x @ concat_map f xs
