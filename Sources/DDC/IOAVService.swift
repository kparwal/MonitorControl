import CoreFoundation
import IOKit

// Private IOKit SPI used on Apple Silicon to talk I2C to external displays.
// Same entry points MonitorControl and m1ddc rely on.

typealias IOAVServiceRef = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVServiceRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVServiceRef, _ chipAddress: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVServiceRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeRawPointer, _ size: UInt32) -> IOReturn
