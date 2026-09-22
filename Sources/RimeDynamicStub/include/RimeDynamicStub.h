#pragma once

// The stub target exports no API. It exists so SwiftPM accepts the target and
// so static-product archiving has an object to include; linking is performed
// through linkerSettings (.linkedFramework("RimeDynamic")) against the
// skeleton frameworks in the release's librime-stub.zip (a full build resolves
// the flag against the app's staged real framework and needs no skeleton).
