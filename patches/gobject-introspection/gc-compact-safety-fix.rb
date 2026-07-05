# frozen_string_literal: true

# gobject-introspection -- GC.compact safety fix for boxed/object class
# converters (Gdk::Event, Pango::Attribute, etc.).
#
# These converters used to cache a Ruby Proc as a raw VALUE inside a plain
# g_malloc'd struct, invisible to Ruby's GC. GC.compact can relocate that
# Proc without anything updating the cached pointer, leaving it dangling;
# the next boxed/object conversion through it then calls rb_funcall on stale
# memory and crashes (SIGBUS/SIGSEGV) -- this is what a periodic GC.compact
# call was triggering roughly every 15 minutes in production.
#
# Roots each converter Proc via rb_gc_register_address (released with
# rb_gc_unregister_address when a converter entry is replaced) instead of
# caching a raw, GC-invisible reference, and removes the now-dead
# protection-array machinery (the @@boxed_class_converters /
# @@object_class_converters class variables and their backing struct field,
# which existed only to keep the reference alive -- this fix makes that
# unnecessary). Ported from patch-ruby-gnome-macos.sh (2026-07), which
# patches an already-installed gem in place; here the same anchor +
# exact-count assertions apply to freshly extracted build source instead.
boxed_comment = [
  '    /* Root the converter Proc via the address of its storage, tied to this',
  "     * entry's lifetime. It was previously cached as a bare VALUE in this",
  '     * g_malloc\'d struct, invisible to the GC, so GC.compact could invalidate',
  '     * the cached reference and the next conversion would call rb_funcall on',
  '     * stale memory. rb_gc_register_address keeps the reference valid across',
  '     * GC and compaction; the matching rb_gc_unregister_address in the free',
  "     * callback releases the Proc when this converter entry is replaced. */",
  "    rb_gc_register_address(&data->rb_converter);\n"
].join("\n")

object_comment =
  "    /* See rg_s_register_boxed_class_converter. */\n" \
  "    rb_gc_register_address(&data->rb_converter);\n"

{
  file: 'ext/gobject-introspection/rb-gi-loader.c',
  marker: 'rb_gc_register_address(&data->rb_converter)',
  steps: [
    # 1. name declarations (both) -> remove
    {
      old: "static const gchar *boxed_class_converters_name = \"@@boxed_class_converters\";\n" \
           "static const gchar *object_class_converters_name = \"@@object_class_converters\";\n",
      new: '',
      count: 1
    },
    # 2. struct field VALUE rb_converters; -> remove from BOTH structs
    { old: "    VALUE rb_converters;\n", new: '', count: 2 },
    # 3. free-callback stale-pointer read -> unregister the root (BOTH callbacks)
    {
      old: "    rb_ary_delete(data->rb_converters, data->rb_converter);\n",
      new: "    rb_gc_unregister_address(&data->rb_converter);\n",
      count: 2
    },
    # 4. boxed register: unused local
    { old: "    VALUE boxed_class_converters;\n", new: '', count: 1 },
    # 5. boxed register: cv_get + push -> rb_gc_register_address
    {
      old: "    boxed_class_converters = rb_cv_get(klass, boxed_class_converters_name);\n" \
           "    rb_ary_push(boxed_class_converters, data->rb_converter);\n",
      new: boxed_comment,
      count: 1
    },
    # 6. object register: unused local
    { old: "    VALUE object_class_converters;\n", new: '', count: 1 },
    # 7. object register: cv_get + push -> rb_gc_register_address
    {
      old: "    object_class_converters = rb_cv_get(klass, object_class_converters_name);\n" \
           "    rb_ary_push(object_class_converters, data->rb_converter);\n",
      new: object_comment,
      count: 1
    },
    # 8. init: cv_set for both class-var arrays -> remove
    {
      old: "    rb_cv_set(RG_TARGET_NAMESPACE, boxed_class_converters_name, rb_ary_new());\n" \
           "    rb_cv_set(RG_TARGET_NAMESPACE, object_class_converters_name, rb_ary_new());\n",
      new: '',
      count: 1
    }
  ],
  # collapse blank lines introduced by the removals (pristine source has none)
  cleanup: ->(content) { content.gsub(/\n\n\n+/, "\n\n") }
}
