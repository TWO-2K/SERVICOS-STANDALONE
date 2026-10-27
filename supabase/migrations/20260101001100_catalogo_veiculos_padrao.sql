-- Catalogo padrao de veiculos (compartilhado por todos os clientes). Sem isso um cliente novo nao consegue
-- cadastrar veiculo, porque marca/modelo/cor sao listas globais. Idempotente: nao duplica o que ja existe.

insert into public.categorias_veiculo (nome)
values ('Carro'), ('Moto'), ('Caminhonete'), ('Utilitario'), ('Caminhao'), ('Onibus')
on conflict (nome) do nothing;

insert into public.cores_veiculo (nome)
values ('Branco'), ('Preto'), ('Prata'), ('Cinza'), ('Vermelho'), ('Azul'), ('Verde'), ('Amarelo'),
       ('Laranja'), ('Marrom'), ('Bege'), ('Vinho'), ('Dourado')
on conflict (nome) do nothing;

insert into public.marcas_veiculo (nome)
values ('Chevrolet'), ('Fiat'), ('Volkswagen'), ('Ford'), ('Toyota'), ('Honda'), ('Hyundai'), ('Renault'),
       ('Jeep'), ('Nissan'), ('Peugeot'), ('Citroen'), ('Mitsubishi'), ('BYD'), ('Yamaha'),
       ('Mercedes-Benz'), ('Volvo'), ('Scania')
on conflict (nome) do nothing;

-- (marca, categoria, modelo)
insert into public.modelos_veiculo (marca_id, categoria_veiculo_id, nome)
select m.id, c.id, v.modelo
from (values
  ('Chevrolet', 'Carro', 'Onix'), ('Chevrolet', 'Carro', 'Prisma'), ('Chevrolet', 'Carro', 'Cruze'),
  ('Chevrolet', 'Carro', 'Tracker'), ('Chevrolet', 'Caminhonete', 'S10'), ('Chevrolet', 'Caminhonete', 'Montana'),
  ('Fiat', 'Carro', 'Uno'), ('Fiat', 'Carro', 'Argo'), ('Fiat', 'Carro', 'Mobi'), ('Fiat', 'Carro', 'Pulse'),
  ('Fiat', 'Caminhonete', 'Strada'), ('Fiat', 'Caminhonete', 'Toro'), ('Fiat', 'Utilitario', 'Fiorino'),
  ('Fiat', 'Utilitario', 'Ducato'),
  ('Volkswagen', 'Carro', 'Gol'), ('Volkswagen', 'Carro', 'Polo'), ('Volkswagen', 'Carro', 'Virtus'),
  ('Volkswagen', 'Carro', 'T-Cross'), ('Volkswagen', 'Caminhonete', 'Saveiro'), ('Volkswagen', 'Caminhonete', 'Amarok'),
  ('Ford', 'Carro', 'Ka'), ('Ford', 'Carro', 'Fiesta'), ('Ford', 'Carro', 'Focus'), ('Ford', 'Caminhonete', 'Ranger'),
  ('Toyota', 'Carro', 'Corolla'), ('Toyota', 'Carro', 'Yaris'), ('Toyota', 'Carro', 'Etios'),
  ('Toyota', 'Caminhonete', 'Hilux'), ('Toyota', 'Carro', 'SW4'),
  ('Honda', 'Carro', 'Civic'), ('Honda', 'Carro', 'Fit'), ('Honda', 'Carro', 'HR-V'),
  ('Honda', 'Moto', 'CG 160'), ('Honda', 'Moto', 'Biz'), ('Honda', 'Moto', 'CB 500'),
  ('Hyundai', 'Carro', 'HB20'), ('Hyundai', 'Carro', 'Creta'), ('Hyundai', 'Utilitario', 'HR'),
  ('Renault', 'Carro', 'Kwid'), ('Renault', 'Carro', 'Sandero'), ('Renault', 'Carro', 'Duster'),
  ('Renault', 'Utilitario', 'Master'),
  ('Jeep', 'Carro', 'Renegade'), ('Jeep', 'Carro', 'Compass'),
  ('Nissan', 'Carro', 'Kicks'), ('Nissan', 'Caminhonete', 'Frontier'),
  ('Peugeot', 'Carro', '208'), ('Citroen', 'Carro', 'C3'),
  ('Mitsubishi', 'Caminhonete', 'L200'), ('Mitsubishi', 'Carro', 'Pajero'),
  ('BYD', 'Carro', 'Dolphin'),
  ('Yamaha', 'Moto', 'Fazer 250'), ('Yamaha', 'Moto', 'Factor 150'),
  ('Mercedes-Benz', 'Caminhao', 'Actros'), ('Mercedes-Benz', 'Utilitario', 'Sprinter'),
  ('Volvo', 'Caminhao', 'FH'), ('Scania', 'Caminhao', 'R 450'), ('Scania', 'Onibus', 'K 360')
) as v(marca, categoria, modelo)
join public.marcas_veiculo m on m.nome = v.marca
join public.categorias_veiculo c on c.nome = v.categoria
on conflict (marca_id, categoria_veiculo_id, nome) do nothing;
