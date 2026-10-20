#pragma once
// The SDK requests GLEW, but GTK/Flutter already use libepoxy. Use the same
// context-aware dispatch on GLX and EGL/Wayland instead of global GLEW pointers.
#include <epoxy/gl.h>
