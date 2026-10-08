import { Component, OnInit } from '@angular/core';

@Component({
  selector: 'app-root',
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.css']
})
export class AppComponent implements OnInit {
  title = 'Oficina Virtual · ensayo Angular 11';
  ambiente = 'cargando…';

  async ngOnInit(): Promise<void> {
    // La configuración del ambiente se lee en tiempo de ejecución (la provee el servidor),
    // en lugar de compilarla con environment.ts.
    try {
      const respuesta = await fetch('assets/config/config.json');
      this.ambiente = (await respuesta.json()).ambiente || 'sin dato';
    } catch {
      this.ambiente = 'sin configuración';
    }
  }
}
