BUILD_DIR ?= build

.PHONY: configure build shader clean

configure:
	cmake -S . -B $(BUILD_DIR) -G Ninja

build:
	cmake --build $(BUILD_DIR)

shader:
	cmake --build $(BUILD_DIR) --target flashlight-shader

clean:
	rm -rf $(BUILD_DIR)
