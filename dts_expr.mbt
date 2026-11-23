// Arithmetic expressions in cell values.
//
// dtc evaluates `( ... )` at parse time, so the blob carries a number and the
// expression never reaches the binary form. The grammar is the one in the DTS
// specification §6.3, with the precedence table from the dtc grammar file:
//
//   ?:             right associative, lowest
//   |              bitwise or
//   ^              bitwise xor
//   &              bitwise and
//   == !=          equality
//   < <= > >=      relational
//   << >>          shifts
//   + -            additive
//   * / %          multiplicative
//   ~ ! -          unary
//
// Evaluation is on `Int64`, not `UInt64`, because a cell is an `Int64` value
// in dtc and the comparisons have to see negatives: `(-1) < 0` is true there,
// while an unsigned comparison would make it false. The result is then masked
// to the cell width the enclosing `/bits/` asks for, which is what turns `-1`
// into `0xFFFFFFFF` for a 32-bit cell.

///|
/// An error raised while reading or evaluating an expression.
///
/// Separate from `ParseError` because the message names what was wrong with
/// the arithmetic rather than where the token was, and the caller that wants a
/// position already has one from the surrounding parse.
pub suberror ExprError {
  /// Division or remainder by a literal zero.
  DivisionByZero
  /// A shift count outside `0..<64`.
  BadShift(amount~ : Int64)
  /// A unary minus applied to the most negative value, which has no positive.
  Overflow(what~ : String)
}

///|
/// A parsed expression.
///
/// Kept as a tree rather than folded during parsing because the value is not
/// needed until the whole cell list is known: dtc evaluates each parenthesised
/// group on its own, and folding early would make the error position point at
/// the operator rather than at the group.
pub(all) enum Expr {
  /// A literal.
  Lit(Int64)
  /// A binary operator.
  Bin(BinOp, Expr, Expr)
  /// A unary operator.
  Un(UnOp, Expr)
  /// `cond ? yes : no`
  Ternary(Expr, Expr, Expr)
}

///|
/// Binary operators in precedence order, lowest first.
pub(all) enum BinOp {
  /// `|`
  Or
  /// `^`
  Xor
  /// `&`
  And
  /// `==`
  Eq
  /// `!=`
  Ne
  /// `<`
  Lt
  /// `<=`
  Le
  /// `>`
  Gt
  /// `>=`
  Ge
  /// `<<`
  Shl
  /// `>>`
  Shr
  /// `+`
  Add
  /// `-`
  Sub
  /// `*`
  Mul
  /// `/`
  Div
  /// `%`
  Mod
}

///|
/// Unary operators.
pub(all) enum UnOp {
  /// `~`
  Not
  /// `!`
  LogicalNot
  /// `-`
  Neg
}

///|
/// Evaluates an expression to a signed 64-bit value.
///
/// Signed because that is what the operators mean: dtc's evaluator works on
/// `int64_t`, so `/` truncates toward zero and `<` compares signed. The caller
/// masks afterwards.
pub fn eval_expr(e : Expr) -> Int64 raise ExprError {
  match e {
    Lit(v) => v
    Un(op, operand) => {
      let v = eval_expr(operand)
      match op {
        // Bitwise complement, which MoonBit spells as `-v - 1` because it
        // has no `~` operator.
        Not => -v - 1L
        LogicalNot => if v == 0L { 1L } else { 0L }
        Neg => {
          // The most negative value has no positive counterpart, and negating
          // it silently yields itself. dtc wraps here; this reports instead,
          // because a wrapped value in a cell is a wrong address rather than a
          // wrong computation about to be corrected.
          if v == -0x7FFF_FFFF_FFFF_FFFFL - 1L {
            raise Overflow(what="negation of the smallest Int64")
          }
          -v
        }
      }
    }
    Ternary(cond, yes, no) =>
      if eval_expr(cond) != 0L {
        eval_expr(yes)
      } else {
        eval_expr(no)
      }
    Bin(op, left, right) => {
      // `&&` and `||` short-circuit in C, but they are not part of this
      // grammar; every operator here evaluates both sides.
      let a = eval_expr(left)
      let b = eval_expr(right)
      match op {
        Or => a | b
        Xor => a ^ b
        And => a & b
        Eq => if a == b { 1L } else { 0L }
        Ne => if a != b { 1L } else { 0L }
        Lt => if a < b { 1L } else { 0L }
        Le => if a <= b { 1L } else { 0L }
        Gt => if a > b { 1L } else { 0L }
        Ge => if a >= b { 1L } else { 0L }
        Shl => shift_left(a, b)
        Shr => shift_right(a, b)
        Add => a + b
        Sub => a - b
        Mul => a * b
        Div => if b == 0L { raise DivisionByZero } else { a / b }
        Mod => if b == 0L { raise DivisionByZero } else { a % b }
      }
    }
  }
}

///|
/// Shifts left, rejecting a count the width cannot express.
///
/// C leaves out-of-range shifts undefined and dtc inherits that; a count of 64
/// or more is a mistake in the source rather than something to wrap, so it is
/// reported and the caller can point at the expression.
fn shift_left(value : Int64, amount : Int64) -> Int64 raise ExprError {
  if amount < 0L || amount > 63L {
    raise BadShift(amount~)
  }
  value << amount.to_int()
}

///|
/// Shifts right, rejecting a count the width cannot express.
///
/// `>>` on a negative value is arithmetic in dtc's evaluator, which is what a
/// signed shift gives here.
fn shift_right(value : Int64, amount : Int64) -> Int64 raise ExprError {
  if amount < 0L || amount > 63L {
    raise BadShift(amount~)
  }
  value >> amount.to_int()
}

///|
/// Masks an evaluated value to the cell width the `/bits/` directive asked
/// for.
///
/// A width of 32 or less keeps the low bits; 64 keeps everything. This is the
/// step that makes `(-1)` a legal `0xFFFFFFFF` cell rather than an error, which
/// is how dtc behaves and how kernel sources use it.
pub fn mask_to_width(value : Int64, width : UInt64) -> UInt64 {
  let raw = value.to_int().reinterpret_as_uint().to_uint64()
  if width >= 64UL {
    raw
  } else if width == 0UL {
    0UL
  } else {
    raw & ((1UL << width.to_int()) - 1UL)
  }
}
