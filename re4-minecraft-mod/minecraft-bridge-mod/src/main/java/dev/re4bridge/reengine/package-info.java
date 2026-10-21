/**
 * Pure-Java writers for Resident Evil 4 (2023, RE Engine) resource files, used to turn Minecraft model parts into
 * real RE4 objects at runtime (no Minecraft classes, no libraries).
 *
 * <ul>
 *   <li>{@link dev.re4bridge.reengine.ReMeshWriter}: {@code .mesh.221108797}, one static mesh with one material</li>
 *   <li>{@link dev.re4bridge.reengine.ReTexWriter}: {@code .tex.143221013}, R8G8B8A8 with mip chain</li>
 *   <li>{@link dev.re4bridge.reengine.ReMdfWriter}: {@code .mdf2.32}, Env_Default material(s)</li>
 * </ul>
 *
 * <p>Files go under {@code <RE4>/natives/STM/} (REFramework's loose file loader). Inside the game files paths
 * are written without {@code natives/STM/} and without the version suffix: the material binds
 * {@code minecraft/zombie/zombie.tex} for {@code natives/STM/minecraft/zombie/zombie.tex.143221013}, and Lua loads
 * {@code minecraft/zombie/head.mesh} / {@code minecraft/zombie/zombie.mdf2}. The material name stored in the mesh
 * must equal the material name in the mdf2.
 *
 * <p>Typical part: geometry with both windings ({@link dev.re4bridge.reengine.ReMeshWriter#withBackFaces}) and a
 * single-sided material; textures upscaled with {@link dev.re4bridge.reengine.ReTexWriter#upscaleNearest} and
 * written as {@link dev.re4bridge.reengine.ReTexWriter.Kind#BASE_DIELECTRIC}; for textures with transparent pixels
 * also an ATOS map ({@link dev.re4bridge.reengine.ReTexWriter#alphaToAtos}, {@code LINEAR_DATA}) and
 * {@link dev.re4bridge.reengine.ReMdfWriter.Material#alphaTest}.
 *
 * <p>{@link dev.re4bridge.reengine.ReFormatsSelfTest} writes sample files for checking with external tools.
 */
package dev.re4bridge.reengine;
