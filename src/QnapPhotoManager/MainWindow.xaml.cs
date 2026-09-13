using System.Windows;
using QnapPhotoManager.Infrastructure;
using QnapPhotoManager.Services;
using QnapPhotoManager.ViewModels;

namespace QnapPhotoManager;

public partial class MainWindow : Window
{
    public MainWindow() : this(new MessageBoxConfirmationService())
    {
    }

    public MainWindow(IConfirmationService confirmationService)
    {
        InitializeComponent();

        var pathPolicy = new PathPolicy(AppContext.BaseDirectory);
        var artifactStore = new AtomicArtifactStore(pathPolicy);
        var duplicateWorkflow = new DuplicateWorkflowService(
            new PowerShellScriptRunner(), artifactStore, pathPolicy);
        DataContext = new MainViewModel(
            new WorkflowStateMachine(),
            artifactStore,
            new DateRepairService(pathPolicy),
            duplicateWorkflow,
            confirmationService);
    }
}
