#pragma once

// The stub target exports no API. It exists so SwiftPM accepts the target and
// so static-product archiving has an object to include; linking is performed
// through linkerSettings (.linkedFramework("RimeDynamic")) against the
// committed skeleton frameworks under <platform>/RimeDynamic.framework.
