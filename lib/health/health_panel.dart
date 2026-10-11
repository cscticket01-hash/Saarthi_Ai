import 'package:flutter/material.dart';
import 'universal_health.dart';
import 'health_diagnostics.dart';

class UniversalHealthPanel extends StatelessWidget {
  const UniversalHealthPanel({super.key,this.engine});
  final UniversalHealth? engine;
  @override Widget build(BuildContext context) {
    final health=engine??UniversalHealth.instance;
    return StreamBuilder<void>(stream:health.changes,builder:(context,_) {
      final entries=health.observations;
      return Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        const Text('Universal Self-Healing 2.0',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),
        Text('Application: ${health.overall.name} • ${health.registeredCount} registered • ${entries.values.where((e)=>e.state==HealthState.healthy).length} recently verified'),
        Text('Active recoveries: ${health.activeRepairs} • Unsettled/quarantined: ${health.unsettledRepairs} • Verified repairs: ${health.history.where((e)=>e.stage=='verified').length} • Last check: ${health.lastCheckAt?.toLocal().toString()??'Unknown'}'),
        const Text('Offline monitoring. Unknown means insufficient evidence. Smart Sync owns all submissions and acknowledgements.'),
        Wrap(spacing:8,children:[OutlinedButton(onPressed:health.paused?health.resume:health.pause,child:Text(health.paused?'Resume monitoring':'Pause monitoring')),OutlinedButton(onPressed:health.paused?null:()=>health.checkAll(),child:const Text('Check health'))]),
        Wrap(spacing:8,runSpacing:4,children:[for(final e in entries.entries)Chip(label:Text('${e.key}: ${e.value.state.name}${e.value.failure==HealthFailure.none?'':' / ${e.value.failure.name}'}'))]),
        for(final diagnosis in HealthDiagnostics.diagnose(health))Text('${diagnosis.component}: ${diagnosis.failure.name} — ${diagnosis.evidence}${diagnosis.possibleSharedCause==null?'':' • ${diagnosis.possibleSharedCause}'}'),
        for(final prediction in health.predictions)Text('Warning (uncalibrated heuristic, ${prediction.samples} samples): ${prediction.component} — ${prediction.reason}'),
        ExpansionTile(title:const Text('Verified recovery history'),children:[for(final event in health.history.reversed.take(12))ListTile(dense:true,title:Text('${event.component} — ${event.stage}'),subtitle:Text('${event.failure.name} • ${event.at.toLocal()}'))]),
      ])));
    });
  }
}
