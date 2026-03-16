# AddEventPage - Registration Fee Feature

1. [x] Add _feeController to AddEventPage state vars
2. [x] Add conditional 'Registration Fee' TextField after Payment Type when !_isFree (Paid), with TextInputType.number and Icons.attach_money
3. [x] Parse fee value and add 'fee': double.tryParse(_feeController.text) ?? 0.0 to event map in Publish button
4. [] Display fee in OngoingEventsPage and HomePage event cards when type == 'Paid' (e.g., "₹${event['fee']}")
5. [] Update TODO.md and test `flutter run`

**Legend:** [x] = Completed, [] = Pending


