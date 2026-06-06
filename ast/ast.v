// Phase 01 — the AST produced by parsing a component's `.html` template.
// Plain V; no compiler builtins. See ../docs/ARCHITECTURE.md.
module ast

pub enum NodeKind {
	element       // an ordinary HTML element, e.g. <div>
	text          // literal text
	interpolation // {{ expr }}
	component     // a PascalCase tag, e.g. <Button>
}

// A static attribute: name="value".
pub struct Attr {
pub:
	name  string
	value string
}

// A bound attribute on an element: :name="expr".
pub struct AttrBinding {
pub:
	name string
	expr string
}

// An event handler: @name[.modifiers]="handler_expr".
pub struct Event {
pub:
	name         string   // e.g. 'click', 'submit'
	handler_expr string   // e.g. 'inc' or 'remove(item.id)'
	modifiers    []string // e.g. ['prevent'] for @submit.prevent
}

// Two-way binding: @bind="signal".
pub struct Binding {
pub:
	target_expr string
}

// Conditional render: @if="cond".
pub struct Cond {
pub:
	expr string
}

// Keyed list render: @for="item in source" :key="key_expr".
pub struct Each {
pub:
	item_name   string
	source_expr string
	key_expr    string
}

// Dynamic class toggle: class:name="expr".
pub struct ClassBinding {
pub:
	name string
	expr string
}

// A prop passed to a child component. Static (label="x") or bound (:label="x").
pub struct Prop {
pub:
	name  string
	bound bool   // true for :name="expr", false for name="value"
	expr  string // set when bound
	value string // set when static
}

// One AST node.
pub struct Node {
pub mut:
	kind           NodeKind
	tag            string         // element/component tag name
	text           string         // for .text nodes
	expr           string         // for .interpolation nodes
	attrs          []Attr         // static attributes (elements)
	attr_bindings  []AttrBinding  // :name="expr" (elements)
	events         []Event        // @name handlers
	binding        ?Binding       // @bind
	cond           ?Cond          // @if
	each           ?Each          // @for (+ :key)
	class_bindings []ClassBinding // class:name
	props          []Prop         // props (components)
	children       []Node
	self_closing   bool
}

// attr returns a static attribute's value, or an error if absent.
pub fn (n Node) attr(name string) !string {
	for a in n.attrs {
		if a.name == name {
			return a.value
		}
	}
	return error('no attribute "${name}" on <${n.tag}>')
}

// prop returns a component prop by name, or an error if absent.
pub fn (n Node) prop(name string) !Prop {
	for p in n.props {
		if p.name == name {
			return p
		}
	}
	return error('no prop "${name}" on <${n.tag}>')
}

// A parsed template: a single root node.
pub struct Tree {
pub mut:
	root Node
}
