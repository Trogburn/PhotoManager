using PhotoManager.Services;

namespace PhotoManager.ViewModels;

internal interface IShellWorkflowHost
{
    string ScanRoot { get; }
    string ArtifactRoot { get; }
    string QuarantineRoot { get; }
    string SessionId { get; }
    WorkflowPage CurrentPage { get; }
    WorkflowStateMachine Workflow { get; }
    AtomicArtifactStore Artifacts { get; }
    IConfirmationService Confirmation { get; }
    void SetStatus(string message);
    void Navigate(WorkflowPage page);
    void RefreshSession();
    void RaiseCommandStates();
}
