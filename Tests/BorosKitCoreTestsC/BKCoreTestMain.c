// BorosKit plain-C core tests: the runner (see BKCoreTest.h).
//
// Original BorosKit code written for this project; contains no third-party code.
// Written 2026-11-25 by agent "vulkan-engine" (Vulkan engine kickoff, step M4).
//
// Use:  bk_core_tests            run every test
//       bk_core_tests NAME ...   run only the named tests (ctest runs each test on its own this way)
//       bk_core_tests --list     print the test names
// Exit: 0 = all checks passed, 1 = at least one failed, 2 = unknown test name.

#include "BKCoreTest.h"
#include <string.h>

int bk_test_checks = 0;
int bk_test_failures = 0;
static const char *gCurrentTest = "";

void bk_test_fail(const char *file, int line, const char *what)
{
    bk_test_failures++;
    // Only the file name, not the whole path (the same output on every machine).
    const char *name = file;
    for (const char *p = file; *p; p++) if (*p == '/' || *p == '\\') name = p + 1;
    printf("  FAIL [%s] %s:%d: %s\n", gCurrentTest, name, line, what);
}

// The tests (each file declares its own; listed here once).
void bk_test_vec_basics(void);
void bk_test_gpu_types_layout(void);
void bk_test_camera_right_vector(void);
void bk_test_camera_ortho_ray_and_scale(void);
void bk_test_camera_perspective_ray(void);
void bk_test_camera_project_inverts_ray(void);
void bk_test_camera_world_delta(void);
void bk_test_mesh_facing_rule(void);
void bk_test_mesh_texture_expand_rule(void);
void bk_test_mesh_texture_sample_rule(void);
void bk_test_mesh_camera_axes(void);
void bk_test_mesh_uniforms_fill(void);
void bk_test_mesh_uniforms_model_and_colour(void);
void bk_test_mesh_depth_range(void);
void bk_test_once_single_thread(void);
void bk_test_once_many_threads(void);
void bk_test_golden_phantom(void);
void bk_test_golden_cpu_numbers(void);
void bk_test_golden_cpu_meshes(void);
void bk_test_roi_accuracy_length(void);
void bk_test_roi_accuracy_angle(void);
void bk_test_roi_accuracy_area(void);
void bk_test_roi_accuracy_stats(void);
void bk_test_roi_accuracy_centre(void);
void bk_test_mesh_accuracy_box(void);
void bk_test_export_accuracy_geometry(void);
// 2026-11-26 (agent "segmentation"): segmentations as label maps (BKSegmentationTests.c)
void bk_test_seg_round_trip(void);
void bk_test_seg_damaged_files(void);
void bk_test_seg_counts_volumes(void);
void bk_test_seg_slices_planes(void);
void bk_test_seg_overlay_picture(void);
void bk_test_seg_mask_surface(void);
// 2026-11-26 (agent "vulkan-engine"): the ray caster's parameter block (BKRenderParamsTests.c)
void bk_test_render_params_frame(void);
void bk_test_render_params_fields(void);
void bk_test_render_params_clut(void);

static const struct { const char *name; BKCoreTestFunction run; } kTests[] = {
    { "vec_basics", bk_test_vec_basics },
    { "gpu_types_layout", bk_test_gpu_types_layout },
    { "camera_right_vector", bk_test_camera_right_vector },
    { "camera_ortho_ray_and_scale", bk_test_camera_ortho_ray_and_scale },
    { "camera_perspective_ray", bk_test_camera_perspective_ray },
    { "camera_project_inverts_ray", bk_test_camera_project_inverts_ray },
    { "camera_world_delta", bk_test_camera_world_delta },
    { "mesh_facing_rule", bk_test_mesh_facing_rule },
    { "mesh_texture_expand_rule", bk_test_mesh_texture_expand_rule },
    { "mesh_texture_sample_rule", bk_test_mesh_texture_sample_rule },
    { "mesh_camera_axes", bk_test_mesh_camera_axes },
    { "mesh_uniforms_fill", bk_test_mesh_uniforms_fill },
    { "mesh_uniforms_model_and_colour", bk_test_mesh_uniforms_model_and_colour },
    { "mesh_depth_range", bk_test_mesh_depth_range },
    { "once_single_thread", bk_test_once_single_thread },
    { "once_many_threads", bk_test_once_many_threads },
    { "golden_phantom", bk_test_golden_phantom },
    { "golden_cpu_numbers", bk_test_golden_cpu_numbers },
    { "golden_cpu_meshes", bk_test_golden_cpu_meshes },
    { "roi_accuracy_length", bk_test_roi_accuracy_length },
    { "roi_accuracy_angle", bk_test_roi_accuracy_angle },
    { "roi_accuracy_area", bk_test_roi_accuracy_area },
    { "roi_accuracy_stats", bk_test_roi_accuracy_stats },
    { "roi_accuracy_centre", bk_test_roi_accuracy_centre },
    { "mesh_accuracy_box", bk_test_mesh_accuracy_box },
    { "export_accuracy_geometry", bk_test_export_accuracy_geometry },
    { "seg_round_trip", bk_test_seg_round_trip },
    { "seg_damaged_files", bk_test_seg_damaged_files },
    { "seg_counts_volumes", bk_test_seg_counts_volumes },
    { "seg_slices_planes", bk_test_seg_slices_planes },
    { "seg_overlay_picture", bk_test_seg_overlay_picture },
    { "seg_mask_surface", bk_test_seg_mask_surface },
    { "render_params_frame", bk_test_render_params_frame },
    { "render_params_fields", bk_test_render_params_fields },
    { "render_params_clut", bk_test_render_params_clut },
};
static const int kTestCount = (int)(sizeof kTests / sizeof kTests[0]);

static int run(int i)
{
    int before = bk_test_failures, checksBefore = bk_test_checks;
    gCurrentTest = kTests[i].name;
    kTests[i].run();
    int failed = bk_test_failures - before;
    printf("%s %s (%d checks)\n", failed ? "FAILED" : "ok    ", kTests[i].name, bk_test_checks - checksBefore);
    return failed;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--list") == 0) {
        for (int i = 0; i < kTestCount; i++) printf("%s\n", kTests[i].name);
        return 0;
    }
    if (argc == 1) {
        for (int i = 0; i < kTestCount; i++) run(i);
    } else {
        for (int a = 1; a < argc; a++) {
            int found = -1;
            for (int i = 0; i < kTestCount; i++) if (strcmp(argv[a], kTests[i].name) == 0) found = i;
            if (found < 0) { printf("unknown test: %s\n", argv[a]); return 2; }
            run(found);
        }
    }
    printf("%d checks, %d failed\n", bk_test_checks, bk_test_failures);
    return bk_test_failures ? 1 : 0;
}
