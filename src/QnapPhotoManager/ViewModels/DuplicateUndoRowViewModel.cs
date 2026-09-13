using QnapPhotoManager.Infrastructure;
using QnapPhotoManager.Models;

namespace QnapPhotoManager.ViewModels;

public sealed class DuplicateUndoRowViewModel(
    DuplicateTransactionEntry entry,
    Action selectionChanged) : ObservableObject
{
    private bool _isSelected;

    public string Source => entry.Source;
    public string Destination => entry.Destination;
    public string MovedAt => entry.TransactionUtc.ToLocalTime().ToString("g");
    public string Status => entry.Status;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value))
            {
                selectionChanged();
            }
        }
    }
}
