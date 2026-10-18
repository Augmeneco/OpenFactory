class_name NoiseExpression
extends RefCounted
## A small evaluator for Factorio's noise expression language.
##
## Every one of the 504 ``noise-expression`` prototypes and the 48
## ``noise-function`` prototypes in the game ships its body as text, looking
## like this:
##
##     clamp(sea_level_temperature + var('control:temperature:bias')
##         + quick_multioctave_noise{x = x, y = y, seed0 = map_seed, ...}, -20, 50)
##
## so this parses that text into a tree once and evaluates it per tile.  The
## named functions are the ones the game defines in Lua; everything else is an
## engine primitive, implemented here.

## Nodes are dictionaries: ``{k = "num"|"str"|"name"|"call"|"bin"|"un", ...}``.

var expressions: Dictionary = {}     ## name -> { params, body } or a literal
var _parsed: Dictionary = {}         ## name -> AST
var _literal: Dictionary = {}        ## name -> float for the plain numbers
var _parsing: Dictionary = {}        ## guards against a recursive definition
var unsupported: Dictionary = {}     ## primitive -> how many times it was hit
## Inputs the engine supplies per position rather than the dump.
##
## Almost every expression is closed over the data, but a few read a value the
## C++ side computes — ``sea_level_temperature`` is the clearest, and it is a
## map setting with a known default.  Anything not listed here evaluates as
## zero, and the tests record which top-level fields that leaves flat.
var engine_variables: Dictionary = {
	"sea_level_temperature": 15.0,
	"map_seed_small": 0.0,
	"starting_area_radius": 0.0,
}
var _evaluations := 0


func _init() -> void:
	_load()


func _load() -> void:
	for name: String in Prototypes.all("noise-expression"):
		var proto := Prototypes.get_p("noise-expression", name)
		var body: Variant = proto.get("expression")
		if body is float or body is int:
			_literal[name] = float(body)
		elif body is String:
			expressions[name] = {"params": [], "body": body}
	for name: String in Prototypes.all("noise-function"):
		var proto := Prototypes.get_p("noise-function", name)
		var body: Variant = proto.get("expression")
		var params: Variant = proto.get("parameters", [])
		if body is String:
			expressions[name] = {
				"params": params if params is Array else [],
				"body": body,
			}


func has(name: String) -> bool:
	return expressions.has(name) or _literal.has(name)


# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------

class Parser:
	var text := ""
	var pos := 0
	var error := ""

	func parse(source: String) -> Dictionary:
		text = source
		pos = 0
		error = ""
		var node := _expression()
		_skip_space()
		if pos < text.length() and error.is_empty():
			error = "unexpected '%s' at %d" % [text[pos], pos]
		return node

	func _skip_space() -> void:
		while pos < text.length():
			var c := text[pos]
			if c == " " or c == "\t" or c == "\n" or c == "\r":
				pos += 1
			elif c == "-" and pos + 1 < text.length() and text[pos + 1] == "-":
				# A Lua line comment.
				while pos < text.length() and text[pos] != "\n":
					pos += 1
			else:
				break

	func _peek() -> String:
		_skip_space()
		return text[pos] if pos < text.length() else ""

	func _accept(symbol: String) -> bool:
		_skip_space()
		if text.substr(pos, symbol.length()) == symbol:
			pos += symbol.length()
			return true
		return false

	## Comparison sits at the top, then ``&``, ``+ -``, ``* / %``, ``^``.
	func _expression() -> Dictionary:
		var left := _bitwise()
		for symbol: String in [">=", "<=", "==", "!=", ">", "<"]:
			_skip_space()
			if text.substr(pos, symbol.length()) != symbol:
				continue
			# ``>`` must not swallow the ``=`` of ``>=``.
			if symbol == ">" and text.substr(pos, 2) == ">=":
				continue
			if symbol == "<" and text.substr(pos, 2) == "<=":
				continue
			pos += symbol.length()
			return {"k": "bin", "op": symbol, "a": left, "b": _bitwise()}
		return left

	func _bitwise() -> Dictionary:
		var left := _sum()
		while _accept("&"):
			left = {"k": "bin", "op": "&", "a": left, "b": _sum()}
		return left

	func _sum() -> Dictionary:
		var left := _product()
		while true:
			var c := _peek()
			if c == "+" or c == "-":
				pos += 1
				left = {"k": "bin", "op": c, "a": left, "b": _product()}
			else:
				break
		return left

	func _product() -> Dictionary:
		var left := _power()
		while true:
			var c := _peek()
			if c == "*" or c == "/" or c == "%":
				pos += 1
				left = {"k": "bin", "op": c, "a": left, "b": _power()}
			else:
				break
		return left

	func _power() -> Dictionary:
		var base := _unary()
		if _accept("^"):
			# Right associative.
			return {"k": "bin", "op": "^", "a": base, "b": _power()}
		return base

	func _unary() -> Dictionary:
		_skip_space()
		if _accept("-"):
			return {"k": "un", "op": "-", "a": _unary()}
		if _accept("+"):
			return _unary()
		if _accept("!"):
			return {"k": "un", "op": "!", "a": _unary()}
		return _postfix()

	func _postfix() -> Dictionary:
		var node := _primary()
		while true:
			_skip_space()
			var c := _peek()
			if c == "(":
				pos += 1
				var args := _arguments(")")
				node = {"k": "call", "name": _call_name(node), "args": args,
					"kwargs": {}, "target": node}
			elif c == "{":
				pos += 1
				var kwargs := _keywords()
				node = {"k": "call", "name": _call_name(node), "args": [],
					"kwargs": kwargs, "target": node}
			else:
				break
		return node

	static func _call_name(node: Dictionary) -> String:
		return str(node.get("v", "")) if str(node.get("k", "")) == "name" else ""

	func _arguments(closer: String) -> Array:
		var out: Array = []
		_skip_space()
		if _accept(closer):
			return out
		while true:
			out.append(_expression())
			if _accept(","):
				continue
			_accept(closer)
			break
		return out

	func _keywords() -> Dictionary:
		var out: Dictionary = {}
		_skip_space()
		if _accept("}"):
			return out
		while true:
			_skip_space()
			var start := pos
			while pos < text.length() and (text[pos].is_valid_identifier() \
					or text[pos].is_valid_int()):
				pos += 1
			var key := text.substr(start, pos - start)
			_accept("=")
			out[key] = _expression()
			if _accept(","):
				continue
			_accept("}")
			break
		return out

	func _primary() -> Dictionary:
		_skip_space()
		if pos >= text.length():
			error = "unexpected end of expression"
			return {"k": "num", "v": 0.0}
		var c := text[pos]
		if c == "(":
			pos += 1
			var inner := _expression()
			_accept(")")
			return inner
		if c == "'" or c == '"':
			var quote := c
			pos += 1
			var start := pos
			while pos < text.length() and text[pos] != quote:
				pos += 1
			var value := text.substr(start, pos - start)
			pos += 1
			return {"k": "str", "v": value}
		if c.is_valid_int() or c == ".":
			var start := pos
			while pos < text.length() and (text[pos].is_valid_int() or text[pos] == "."):
				pos += 1
			# A trailing exponent belongs to the number.
			if pos < text.length() and (text[pos] == "e" or text[pos] == "E"):
				var save := pos
				pos += 1
				if pos < text.length() and (text[pos] == "+" or text[pos] == "-"):
					pos += 1
				if pos < text.length() and text[pos].is_valid_int():
					while pos < text.length() and text[pos].is_valid_int():
						pos += 1
				else:
					pos = save
			return {"k": "num", "v": float(text.substr(start, pos - start))}
		if c.is_valid_identifier():
			var start := pos
			while pos < text.length() and (text[pos].is_valid_identifier() \
					or text[pos].is_valid_int() or text[pos] == ":"):
				pos += 1
			return {"k": "name", "v": text.substr(start, pos - start)}
		error = "unexpected '%s' at %d" % [c, pos]
		pos += 1
		return {"k": "num", "v": 0.0}


func parse(name: String) -> Dictionary:
	if _parsed.has(name):
		return _parsed[name]
	if not expressions.has(name):
		return {}
	if _parsing.has(name):
		# A cycle would recurse for ever; treat it as zero, as the engine's
		# own expression graph is acyclic and this only happens on a typo.
		push_warning("noise expression cycle at %s" % name)
		return {}
	_parsing[name] = true
	var parser := Parser.new()
	var tree := parser.parse(str(expressions[name]["body"]))
	_parsing.erase(name)
	if not parser.error.is_empty():
		push_warning("noise expression %s: %s" % [name, parser.error])
	_parsed[name] = tree
	return tree


# --------------------------------------------------------------------------
# evaluation
# --------------------------------------------------------------------------

## Evaluate a named expression at a point.
##
## ``variables`` carries the ``var('control:...')`` lookups — the map settings
## sliders — and ``seed`` is Factorio's ``map_seed``.
func evaluate(name: String, x: float, y: float, seed_value: int,
		variables: Dictionary = {}) -> float:
	if _literal.has(name):
		return float(_literal[name])
	var tree := parse(name)
	if tree.is_empty():
		return 0.0
	var context := {
		"x": x, "y": y, "map_seed": float(seed_value),
		"variables": variables, "depth": 0,
	}
	return _eval(tree, context)


func _eval(node: Dictionary, context: Dictionary) -> float:
	_evaluations += 1
	if int(context.get("depth", 0)) > 64:
		return 0.0
	match str(node.get("k", "num")):
		"num":
			return float(node["v"])
		"str":
			return 0.0
		"name":
			return _variable(str(node["v"]), context)
		"un":
			return -_eval(node["a"], context)
		"bin":
			return _binary(str(node["op"]), _eval(node["a"], context),
				_eval(node["b"], context))
		"call":
			return _call(node, context)
	return 0.0


func _variable(name: String, context: Dictionary) -> float:
	# A parameter of the function currently being evaluated shadows anything
	# else of the same name.
	var scope: Variant = context.get("scope", null)
	if scope is Dictionary and (scope as Dictionary).has(name):
		return float(scope[name])
	match name:
		"x":
			return float(context["x"])
		"y":
			return float(context["y"])
		"map_seed":
			return float(context["map_seed"])
		"inf":
			return INF
		"pi":
			return PI
		"e":
			return 2.718281828459045
	if engine_variables.has(name):
		return float(engine_variables[name])
	# Anything else is another named expression.  It is evaluated in place
	# rather than through ``evaluate``: building a fresh context per reference
	# costs more than the arithmetic, and a single tile walks a dozen of these.
	if has(name):
		if _literal.has(name):
			return float(_literal[name])
		var tree := parse(name)
		if tree.is_empty():
			return 0.0
		var saved_scope: Variant = context.get("scope", null)
		context["scope"] = {}
		context["depth"] = int(context.get("depth", 0)) + 1
		var value := _eval(tree, context)
		context["depth"] = int(context["depth"]) - 1
		context["scope"] = saved_scope
		return value
	return 0.0


static func _binary(op: String, a: float, b: float) -> float:
	match op:
		"+":
			return a + b
		"-":
			return a - b
		"*":
			return a * b
		"/":
			return a / b if b != 0.0 else 0.0
		"%":
			return fmod(a, b) if b != 0.0 else 0.0
		"^":
			return pow(a, b)
		"&":
			return float(int(a) & int(b))
		">":
			return 1.0 if a > b else 0.0
		"<":
			return 1.0 if a < b else 0.0
		">=":
			return 1.0 if a >= b else 0.0
		"<=":
			return 1.0 if a <= b else 0.0
		"==":
			return 1.0 if is_equal_approx(a, b) else 0.0
		"!=":
			return 0.0 if is_equal_approx(a, b) else 1.0
	return 0.0


func _call(node: Dictionary, context: Dictionary) -> float:
	var name := str(node.get("name", ""))
	var args: Array = node.get("args", [])
	var kwargs: Dictionary = node.get("kwargs", {})

	# A function the game defines in Lua.
	if expressions.has(name):
		return _user_function(name, args, kwargs, context)

	var x := float(context["x"])
	var y := float(context["y"])
	var seed_value := int(context["map_seed"])

	match name:
		"min":
			return minf(_arg(args, 0, context), _arg(args, 1, context))
		"max":
			return maxf(_arg(args, 0, context), _arg(args, 1, context))
		"clamp":
			var low := _arg(args, 1, context)
			var high := _arg(args, 2, context)
			if low > high:
				var swap := low
				low = high
				high = swap
			return clampf(_arg(args, 0, context), low, high)
		"abs":
			return absf(_arg(args, 0, context))
		"sqrt":
			return sqrt(maxf(0.0, _arg(args, 0, context)))
		"log2":
			var value := _arg(args, 0, context)
			return log(value) / log(2.0) if value > 0.0 else 0.0
		"sin":
			return sin(_arg(args, 0, context))
		"cos":
			return cos(_arg(args, 0, context))
		"floor":
			return floorf(_arg(args, 0, context))
		"ceil":
			return ceilf(_arg(args, 0, context))
		"round":
			return roundf(_arg(args, 0, context))
		"if":
			return _arg(args, 1, context) if _arg(args, 0, context) != 0.0 \
				else _arg(args, 2, context)
		"var":
			var key := str((args[0] as Dictionary).get("v", "")) \
				if not args.is_empty() and args[0] is Dictionary else ""
			var table: Dictionary = context.get("variables", {})
			return float(table.get(key, 0.0))
		"basis_noise":
			return NoiseBasis.basis_noise(
				_kw(kwargs, "x", context, x), _kw(kwargs, "y", context, y),
				int(_kw(kwargs, "seed0", context, float(seed_value))),
				_kw(kwargs, "input_scale", context, 1.0),
				_kw(kwargs, "output_scale", context, 1.0),
				_kw(kwargs, "offset_x", context, 0.0),
				_kw(kwargs, "offset_y", context, 0.0))
		"multioctave_noise", "quick_multioctave_noise", "amplitude_corrected_multioctave_noise":
			return NoiseBasis.multioctave_noise(
				_kw(kwargs, "x", context, x), _kw(kwargs, "y", context, y),
				int(_kw(kwargs, "seed0", context, float(seed_value))),
				int(_kw(kwargs, "seed1", context, 0.0)),
				int(_kw(kwargs, "octaves", context, 4.0)),
				_kw(kwargs, "input_scale", context, 1.0),
				_kw(kwargs, "output_scale", context, 1.0),
				_kw(kwargs, "offset_x", context, 0.0),
				_kw(kwargs, "offset_y", context, 0.0),
				_kw(kwargs, "octave_input_scale_multiplier", context, 0.5),
				_kw(kwargs, "octave_output_scale_multiplier", context, 0.5),
				int(_kw(kwargs, "octave_seed_0_offset", context, 0.0)))
		"variable_persistence_multioctave_noise":
			return NoiseBasis.variable_persistence_noise(
				_kw(kwargs, "x", context, x), _kw(kwargs, "y", context, y),
				int(_kw(kwargs, "seed0", context, float(seed_value))),
				int(_kw(kwargs, "seed1", context, 0.0)),
				int(_kw(kwargs, "octaves", context, 4.0)),
				_kw(kwargs, "input_scale", context, 1.0),
				_kw(kwargs, "output_scale", context, 1.0),
				_kw(kwargs, "persistence", context, 0.5),
				_kw(kwargs, "offset_x", context, 0.0),
				_kw(kwargs, "offset_y", context, 0.0))
		"spot_noise":
			return NoiseBasis.spot_noise(
				_kw(kwargs, "x", context, x), _kw(kwargs, "y", context, y),
				int(_kw(kwargs, "seed0", context, float(seed_value))),
				int(_kw(kwargs, "seed1", context, 0.0)),
				_kw(kwargs, "region_size", context, 512.0),
				int(_kw(kwargs, "candidate_point_count", context, 10.0)),
				_kw(kwargs, "spot_quantity_expression", context, 1.0),
				_kw(kwargs, "spot_radius_expression", context, 1.0),
				_kw(kwargs, "density_expression", context, 1.0))
		"voronoi_cell_id":
			return NoiseBasis.voronoi_cell_id(
				_kw(kwargs, "x", context, x), _kw(kwargs, "y", context, y),
				int(_kw(kwargs, "seed0", context, float(seed_value))),
				int(_kw(kwargs, "seed1", context, 0.0)),
				_kw(kwargs, "grid_size", context, 1.0),
				_kw(kwargs, "jitter", context, 1.0))
		"random_penalty", "random_penalty_at", "random_penalty_between", "random":
			# A per-position hash in [0, 1); good enough for a scatter rule.
			return NoiseBasis.cell_random(int(floor(x)), int(floor(y)),
				seed_value + name.hash())
		"expression_in_range":
			var value := _arg(args, 0, context)
			var low := _kw(kwargs, "min", context, 0.0)
			var high := _kw(kwargs, "max", context, 1.0)
			return 1.0 if value >= low and value <= high else 0.0

	unsupported[name] = int(unsupported.get(name, 0)) + 1
	return 0.0


## Call one of the functions the game itself defines in Lua.
func _user_function(name: String, args: Array, kwargs: Dictionary,
		context: Dictionary) -> float:
	var definition: Dictionary = expressions[name]
	var params: Array = definition["params"]
	var inner := context.duplicate()
	inner["depth"] = int(context.get("depth", 0)) + 1
	var scope: Dictionary = context.get("scope", {}).duplicate()

	# The body is parsed in the caller's scope: parameters shadow it.
	var body_context := context.duplicate()
	body_context["depth"] = inner["depth"]
	var body_scope: Dictionary = scope
	if not kwargs.is_empty():
		for key: String in kwargs:
			body_scope[key] = _eval(kwargs[key], context)
	for index in params.size():
		if index < args.size():
			body_scope[str(params[index])] = _eval(args[index], context)
	body_context["scope"] = body_scope
	var tree: Dictionary = _parsed.get(name, {})
	if tree.is_empty():
		var parser := Parser.new()
		tree = parser.parse(str(definition["body"]))
		_parsed[name] = tree
	# The body may be a bare name referring to another expression.
	if body_scope.is_empty() and args.is_empty() and kwargs.is_empty() \
			and str(tree.get("k", "")) == "name":
		return _variable(str(tree["v"]), context)
	return _eval(tree, body_context)


func _arg(args: Array, index: int, context: Dictionary) -> float:
	if index >= args.size():
		return 0.0
	return _eval(args[index], context)


## A keyword argument, falling back to the default.
func _kw(kwargs: Dictionary, key: String, context: Dictionary,
		fallback: float) -> float:
	if not kwargs.has(key):
		return fallback
	return _eval(kwargs[key], context)


func evaluation_count() -> int:
	return _evaluations
