using PhotoManager.Infrastructure;

namespace PhotoManager.ViewModels;

public sealed class DateBulkApproveGroup
{
    public DateBulkApproveGroup(string key, string label, Action approve)
    {
        Key = key;
        Label = label;
        ApproveCommand = new RelayCommand(approve);
    }

    public string Key { get; }
    public string Label { get; }
    public RelayCommand ApproveCommand { get; }
}
