# CampusSync Date Picker Modification TODO

## Status: In Progress

### Step 1: Create TODO.md [✅ COMPLETE]

### Step 2: Add TextEditingController _dateController to AddEventPage state [✅ COMPLETE - _selectedDate removed, _pickDate removed]
- Location: _AddEventPageState class
- Add: `final TextEditingController _dateController = TextEditingController();`
- Add .dispose() call

### Step 3: Remove _selectedDate state and _pickDate() method
- Remove: `DateTime? _selectedDate;`
- Remove entire: `Future<void> _pickDate() async { ... }`

### Step 4: Replace _buildDateField() with manual date TextField [✅ COMPLETE]
- Replace ListTile picker UI with styled TextField
- Controller: _dateController
- Hint: "Enter date (DD/MM/YYYY)"
- Icon: Icons.calendar_today
- Input formatter for DD/MM/YYYY validation

### Step 5: Add _parseDate(String input) helper method [✅ COMPLETE]
- Parse "DD/MM/YYYY" → DateTime?
- Return null + validation message if invalid
- Use DateTime.tryParse or manual split parsing

### Step 6: Update _publishEvent()
- Validation: Check _dateController.text.trim().isEmpty
- Parse date: DateTime? eventDate = _parseDate(_dateController.text.trim());
- Save: 'eventDate': eventDate!.millisecondsSinceEpoch

### Step 7: Test Changes
- Run `flutter run`
- Test Admin → Add Event page
  - Manual date entry works
  - Invalid date shows error
  - Time picker unchanged
  - Event publishes successfully
- Update TODO.md: Mark all ✅

### Step 4: Replace _buildDateField() with manual date TextField [✅ COMPLETE]

**Next Step:** Step 6 - Update _publishEvent validation + test

**Estimated Time:** 5 minutes

