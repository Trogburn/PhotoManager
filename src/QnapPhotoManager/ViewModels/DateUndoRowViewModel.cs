using QnapPhotoManager.Infrastructure;
using QnapPhotoManager.Models;

namespace QnapPhotoManager.ViewModels;

public sealed class DateUndoRowViewModel(DateUndoEntry entry, Action selectionChanged) : ObservableObject
{
    private bool _isSelected;

    public string Path => entry.Path;
    public string FileName => System.IO.Path.GetFileName(entry.Path);
    public string AppliedAt => entry.AfterCreationTimeUtc.ToLocalTime().ToString("g");
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
