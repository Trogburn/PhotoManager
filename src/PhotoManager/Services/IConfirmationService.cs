namespace PhotoManager.Services;

public interface IConfirmationService
{
    bool Confirm(string message, string title);
}

public sealed class MessageBoxConfirmationService : IConfirmationService
{
    public bool Confirm(string message, string title) =>
        System.Windows.MessageBox.Show(
            message,
            title,
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning) == System.Windows.MessageBoxResult.Yes;
}
