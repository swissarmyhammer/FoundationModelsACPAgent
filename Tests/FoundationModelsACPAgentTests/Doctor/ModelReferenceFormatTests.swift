import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// A model reference is `owner/name[/path][@revision]`. The repository id is
/// always the first two segments; each later segment is a path inside the
/// repository, such as the quantization folder of a GGUF repository.
@Suite struct ModelReferenceFormatTests {
  /// A reference with a path inside the repository splits into the
  /// repository id and the revision; the path is not part of the id.
  @Test func aPathInsideTheRepositoryIsNotPartOfTheRepositoryId() {
    let parts = ModelReferenceFormat.parts(of: "unsloth/Qwen3.8-27B-GGUF/Q4_K_M@rev")
    #expect(parts.repo == "unsloth/Qwen3.8-27B-GGUF")
    #expect(parts.revision == "rev")
  }

  /// A plain reference keeps its whole text as the repository id.
  @Test func aPlainReferenceIsItsRepositoryId() {
    let parts = ModelReferenceFormat.parts(of: "mlx-community/Qwen3.8-27B-4bit")
    #expect(parts.repo == "mlx-community/Qwen3.8-27B-4bit")
    #expect(parts.revision == nil)
  }

  /// A reference that starts with `.` names a folder on the disk, as the
  /// loader reads it.
  @Test func aReferenceThatStartsWithADotIsLocal() {
    #expect(ModelReferenceFormat.isLocalPath("../models/qwen"))
    #expect(!ModelReferenceFormat.isLocalPath("unsloth/Qwen3.8-27B-GGUF/Q4_K_M"))
  }
}
