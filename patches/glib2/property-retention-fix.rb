# frozen_string_literal: true

# glib2 -- GC/property-retention fix.
#
# Ruby-defined GObject properties set via the generic setter lost their
# retained value across a GC cycle: the setter called the Ruby-side setter
# method but never rooted the resulting object against the underlying
# GObject via G_CHILD_SET, so nothing kept the Ruby VALUE alive once GC ran.
# Ported from patch-ruby-gnome-macos.sh (2026-07), which patches an
# already-installed gem in place; here the same anchor + exact-count
# assertion applies to freshly extracted build source instead.
{
  file: 'ext/glib2/rbgobj_object.c',
  marker: 'G_CHILD_SET(rb_object',
  steps: [
    {
      old: '    rb_funcall(GOBJ2RVAL(object), ruby_setter, 1, GVAL2RVAL(value));',
      new: [
        '    {',
        '        VALUE rb_object = GOBJ2RVAL(object);',
        '        VALUE rb_value = GVAL2RVAL(value);',
        '        rb_funcall(rb_object, ruby_setter, 1, rb_value);',
        '        if (G_TYPE_IS_OBJECT(G_PARAM_SPEC_VALUE_TYPE(pspec))) {',
        '            G_CHILD_SET(rb_object, rb_intern(g_param_spec_get_name(pspec)), rb_value);',
        '        }',
        '    }'
      ].join("\n"),
      count: 1
    }
  ]
}
