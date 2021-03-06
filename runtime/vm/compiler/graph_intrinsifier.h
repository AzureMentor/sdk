// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// Class for intrinsifying functions.

#ifndef RUNTIME_VM_COMPILER_GRAPH_INTRINSIFIER_H_
#define RUNTIME_VM_COMPILER_GRAPH_INTRINSIFIER_H_

#include "vm/allocation.h"
#include "vm/compiler/recognized_methods_list.h"

namespace dart {

// Forward declarations.
class FlowGraphCompiler;
class ParsedFunction;
class FlowGraph;

namespace compiler {
class Assembler;
class Label;

#if !defined(TARGET_ARCH_DBC)

class GraphIntrinsifier : public AllStatic {
 public:
  static intptr_t ParameterSlotFromSp();

  static bool GraphIntrinsify(const ParsedFunction& parsed_function,
                              FlowGraphCompiler* compiler);

  static void IntrinsicCallPrologue(Assembler* assembler);
  static void IntrinsicCallEpilogue(Assembler* assembler);

 private:
#define DECLARE_FUNCTION(class_name, function_name, enum_name, fp)             \
  static void enum_name(Assembler* assembler, Label* normal_ir_body);

  // On DBC graph intrinsics are handled in the same way as non-graph ones.
  GRAPH_INTRINSICS_LIST(DECLARE_FUNCTION)

#undef DECLARE_FUNCTION

#define DECLARE_FUNCTION(class_name, function_name, enum_name, fp)             \
  static bool Build_##enum_name(FlowGraph* flow_graph);

  GRAPH_INTRINSICS_LIST(DECLARE_FUNCTION)

#undef DECLARE_FUNCTION
};

#else  // !defined(TARGET_ARCH_DBC)

class GraphIntrinsifier : public AllStatic {
 public:
  static bool GraphIntrinsify(const ParsedFunction& parsed_function,
                              FlowGraphCompiler* compiler) {
    return false;
  }
};

#endif  // !defined(TARGET_ARCH_DBC)

}  // namespace compiler
}  // namespace dart

#endif  // RUNTIME_VM_COMPILER_GRAPH_INTRINSIFIER_H_
