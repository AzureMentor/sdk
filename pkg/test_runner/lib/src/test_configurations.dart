// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'android.dart';
import 'browser_controller.dart';
import 'co19_test_config.dart';
import 'configuration.dart';
import 'path.dart';
import 'process_queue.dart';
import 'test_progress.dart';
import 'test_suite.dart';
import 'utils.dart';

/// The directories that contain test suites which follow the conventions
/// required by [StandardTestSuite]'s forDirectory constructor.
/// New test suites should follow this convention because it makes it much
/// simpler to add them to test.dart.  Existing test suites should be
/// moved to here, if possible.
final TEST_SUITE_DIRECTORIES = [
  Path('third_party/pkg/dartdoc'),
  Path('pkg'),
  Path('third_party/pkg_tested'),
  Path('runtime/tests/vm'),
  Path('runtime/observatory/tests/service'),
  Path('runtime/observatory/tests/observatory_ui'),
  Path('samples'),
  Path('samples-dev'),
  Path('tests/compiler/dart2js'),
  Path('tests/compiler/dart2js_extra'),
  Path('tests/compiler/dart2js_native'),
  Path('tests/compiler/dartdevc_native'),
  Path('tests/corelib_2'),
  Path('tests/kernel'),
  Path('tests/language_2'),
  Path('tests/lib_2'),
  Path('tests/standalone'),
  Path('tests/standalone_2'),
  Path('tests/ffi'),
  Path('utils/tests/peg'),
];

Future testConfigurations(List<TestConfiguration> configurations) async {
  var startTime = DateTime.now();
  var startStopwatch = Stopwatch()..start();

  // Extract global options from first configuration.
  var firstConf = configurations[0];
  var maxProcesses = firstConf.taskCount;
  var progressIndicator = firstConf.progress;
  BuildbotProgressIndicator.stepName = firstConf.stepName;
  var verbose = firstConf.isVerbose;
  var printTiming = firstConf.printTiming;
  var listTests = firstConf.listTests;
  var listStatusFiles = firstConf.listStatusFiles;
  var reportInJson = firstConf.reportInJson;

  Browser.resetBrowserConfiguration = firstConf.resetBrowser;
  DebugLogger.init(firstConf.writeDebugLog ? TestUtils.debugLogFilePath : null);

  // Print the configurations being run by this execution of
  // test.dart. However, don't do it if the silent progress indicator
  // is used.
  if (progressIndicator != Progress.silent) {
    print('Test configuration${configurations.length > 1 ? 's' : ''}:');
    for (var configuration in configurations) {
      print("    ${configuration.configuration}");
      print("Suites tested: ${configuration.selectors.keys.join(", ")}");
    }
  }

  var runningBrowserTests =
      configurations.any((config) => config.runtime.isBrowser);

  var serverFutures = <Future>[];
  var testSuites = <TestSuite>[];
  var maxBrowserProcesses = maxProcesses;
  if (configurations.length > 1 &&
      (configurations[0].testServerPort != 0 ||
          configurations[0].testServerCrossOriginPort != 0)) {
    print("If the http server ports are specified, only one configuration"
        " may be run at a time");
    exit(1);
  }

  for (var configuration in configurations) {
    if (!listTests && !listStatusFiles && runningBrowserTests) {
      serverFutures.add(configuration.startServers());
    }

    if (configuration.runtime.isIE) {
      // NOTE: We've experienced random timeouts of tests on ie9/ie10. The
      // underlying issue has not been determined yet. Our current hypothesis
      // is that windows does not handle the IE processes independently.
      // If we have more than one browser and kill a browser we are seeing
      // issues with starting up a new browser just after killing the hanging
      // browser.
      maxBrowserProcesses = 1;
    } else if (configuration.runtime.isSafari) {
      // Safari does not allow us to run from a fresh profile, so we can only
      // use one browser. Additionally, you can not start two simulators
      // for mobile safari simultaneously.
      maxBrowserProcesses = 1;
    } else if (configuration.runtime == Runtime.chrome &&
        Platform.operatingSystem == 'macos') {
      // Chrome on mac results in random timeouts.
      // Issue: https://github.com/dart-lang/sdk/issues/23891
      // This change does not fix the problem.
      maxBrowserProcesses = math.max(1, maxBrowserProcesses ~/ 2);
    }

    // If we specifically pass in a suite only run that.
    if (configuration.suiteDirectory != null) {
      var suitePath = Path(configuration.suiteDirectory);
      testSuites.add(PKGTestSuite(configuration, suitePath));
    } else {
      for (var testSuiteDir in TEST_SUITE_DIRECTORIES) {
        var name = testSuiteDir.filename;
        if (configuration.selectors.containsKey(name)) {
          testSuites
              .add(StandardTestSuite.forDirectory(configuration, testSuiteDir));
        }
      }

      for (var key in configuration.selectors.keys) {
        if (key == 'co19_2') {
          testSuites.add(Co19TestSuite(configuration, key));
        } else if ((configuration.compiler == Compiler.none ||
                configuration.compiler == Compiler.dartk ||
                configuration.compiler == Compiler.dartkb) &&
            configuration.runtime == Runtime.vm &&
            key == 'vm') {
          // vm tests contain both cc tests (added here) and dart tests (added
          // in [TEST_SUITE_DIRECTORIES]).
          testSuites.add(VMTestSuite(configuration));
        } else if (configuration.compiler == Compiler.dart2analyzer) {
          if (key == 'analyze_library') {
            testSuites.add(AnalyzeLibraryTestSuite(configuration));
          }
        }
      }
    }
  }

  // If we only need to print out status files for test suites
  // we return from running here and just print.
  if (firstConf.listStatusFiles) {
    for (var suite in testSuites) {
      print(suite.suiteName);
      for (var statusFile in suite.statusFilePaths.toSet()) {
        print("\t$statusFile");
      }
    }
    return;
  }

  void allTestsFinished() {
    for (var configuration in configurations) {
      configuration.stopServers();
    }

    DebugLogger.close();
    if (!firstConf.keepGeneratedFiles) {
      TestUtils.deleteTempSnapshotDirectory(configurations[0]);
    }
  }

  var eventListener = <EventListener>[];

  // We don't print progress if we list tests.
  if (progressIndicator != Progress.silent && !listTests) {
    var printFailures = true;
    var formatter = Formatter.normal;
    if (progressIndicator == Progress.color) {
      progressIndicator = Progress.compact;
      formatter = Formatter.color;
    }
    if (progressIndicator == Progress.diff) {
      progressIndicator = Progress.compact;
      formatter = Formatter.color;
      printFailures = false;
      eventListener.add(StatusFileUpdatePrinter());
    }
    if (firstConf.silentFailures) {
      printFailures = false;
    }
    eventListener.add(SummaryPrinter());
    if (printFailures) {
      // The buildbot has it's own failure summary since it needs to wrap it
      // into '@@@'-annotated sections.
      var printFailureSummary = progressIndicator != Progress.buildbot;
      eventListener.add(TestFailurePrinter(printFailureSummary, formatter));
    }
    if (firstConf.printPassingStdout) {
      eventListener.add(PassingStdoutPrinter(formatter));
    }
    eventListener.add(ProgressIndicator.fromProgress(
        progressIndicator, startTime, formatter));
    if (printTiming) {
      eventListener.add(TimingPrinter(startTime));
    }
    eventListener.add(SkippedCompilationsPrinter());
    if (progressIndicator == Progress.status) {
      eventListener.add(TimedProgressPrinter());
    }
  }

  if (firstConf.writeResults) {
    eventListener.add(ResultWriter(firstConf, startTime, startStopwatch));
  }

  if (firstConf.copyCoreDumps) {
    eventListener.add(UnexpectedCrashLogger());
  }

  // The only progress indicator when listing tests should be the
  // the summary printer.
  if (listTests) {
    eventListener.add(SummaryPrinter(jsonOnly: reportInJson));
  } else {
    if (!firstConf.cleanExit) {
      eventListener.add(ExitCodeSetter());
    }
    eventListener.add(IgnoredTestMonitor());
  }

  // If any of the configurations need to access android devices we'll first
  // make a pool of all available adb devices.
  AdbDevicePool adbDevicePool;
  var needsAdbDevicePool = configurations.any((conf) {
    return conf.system == System.android;
  });
  if (needsAdbDevicePool) {
    adbDevicePool = await AdbDevicePool.create();
  }

  // Start all the HTTP servers required before starting the process queue.
  if (!serverFutures.isEmpty) {
    await Future.wait(serverFutures);
  }

  // [firstConf] is needed here, since the ProcessQueue needs to know the
  // settings of 'noBatch' and 'local_ip'
  ProcessQueue(firstConf, maxProcesses, maxBrowserProcesses, testSuites,
      eventListener, allTestsFinished, verbose, adbDevicePool);
}
