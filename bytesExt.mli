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

val read_byte : bytes -> int -> Int32.t

val read_word : bytes -> int -> Int32.t

val read_long : bytes -> int -> Int32.t

val write_byte : bytes -> int -> Int32.t -> unit

val write_word : bytes -> int -> Int32.t -> unit

val write_long : bytes -> int -> Int32.t -> unit
