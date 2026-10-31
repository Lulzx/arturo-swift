LIB := libswift_studio.dylib
SWIFT := studio_host.swift
FRAMEWORKS := -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit
SWIFTC := swiftc -emit-library -O -target arm64-apple-macos14.0 -module-name StudioHost

all: $(LIB)

$(LIB): $(SWIFT)
	$(SWIFTC) $(FRAMEWORKS) $(SWIFT) -o $@

run: $(LIB)
	arturo --no-color scene.art

bundle: $(LIB)
	arturo --no-color bundle.art

clean:
	rm -f $(LIB)

.PHONY: all run bundle clean
