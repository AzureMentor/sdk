// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class A1<T> {}

extension A2<T> on A1<T> {
  A1<T> method1<S extends T>() {
    return this;
  }

  // TODO(johnniwinther): Resolve type variable uses correctly. Currently use
  // `T` here resolve to `A2.T` and the synthetically inserted type variable.
  A1<T> method2<S extends A1<T>>(S o) {
    print(o);
    print(T);
    print(S);
    return this;
  }
}

// TODO(johnniwinther): Support F-bounded extensions. Currently the type
// variable is not recognized as a type within the bound.

main() {}