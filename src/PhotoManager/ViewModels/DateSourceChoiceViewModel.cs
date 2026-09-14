using PhotoManager.Infrastructure;

namespace PhotoManager.ViewModels;

public sealed class DateSourceChoiceViewModel
{
    public DateSourceChoiceViewModel(string label, string dateValue, Action choose, Func<bool>? canChoose = null)
    {
        Label = label;
        DateValue = dateValue;
        ButtonLabel = $"Use {label}";
        ChooseCommand = new RelayCommand(choose, canChoose);
    }

    public string Label { get; }
    public string DateValue { get; }
    public string ButtonLabel { get; }
    public RelayCommand ChooseCommand { get; }
}
