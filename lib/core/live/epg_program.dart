class EpgProgram {
  final String title;
  final DateTime start;
  final DateTime end;
  final String? description;

  const EpgProgram({
    required this.title,
    required this.start,
    required this.end,
    this.description,
  });

  bool isCurrent(DateTime now) => !start.isAfter(now) && end.isAfter(now);
}

class EpgSchedule {
  final List<EpgProgram> programs;
  const EpgSchedule(this.programs);

  EpgProgram? currentAt(DateTime now) {
    for (final program in programs) {
      if (program.isCurrent(now)) return program;
    }
    return null;
  }

  EpgProgram? nextAt(DateTime now) {
    for (final program in programs) {
      if (program.start.isAfter(now)) return program;
    }
    return null;
  }
}
