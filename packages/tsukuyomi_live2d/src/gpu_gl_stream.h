#pragma once
#include <GL/glew.h>
// The official desktop backend uses client arrays, unavailable in GTK's core
// contexts. Keep the official shaders/masks, upload geometry to reusable VBOs.
void ts_gl_vertex(GLuint attribute, int vertices, const float* data);
void ts_gl_indices(GLsizei count, const void* data);
