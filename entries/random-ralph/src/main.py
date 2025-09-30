#!/usr/bin/env python3
from copy import copy
import random
import string
from time import sleep
from dataclasses import dataclass
import sys

# Turn this on to test penatlies for taking too long in between moves
RANDOM_SLEEP = True

@dataclass
class Placement:
    size: int
    orientation: str
    x: int
    y: int

    @staticmethod
    def random(size) -> "Placement":
        return Placement(
            size,
            "vertical" if random.random() > 0.5 else "horizontal",
            random.randint(0 ,9),
            random.randint(0 ,9),
        )

    def __str__(self):
        letter = string.ascii_uppercase[self.y]
        return f"{self.size};{self.orientation};{letter}{self.x}"


@dataclass
class Placements:
    placements: list[Placement]

    def __str__(self) -> str:
        return "place-ships;" + ";".join(str(p) for p in self.placements)


@dataclass
class Move:
    x: int
    y: int

    def __str__(self) -> str:
        letter = string.ascii_uppercase[self.y]
        return f"take-turn;{letter}{self.x}"


@dataclass
class TurnResult:
    who: str
    x: int
    y: int
    shot: str
    size: str | None

    @staticmethod
    def parse(data: str) -> "TurnResult":
        parts = data.split(";")
        (who, coord, shot) = parts[1:4]
        size = parts[4] if shot == "sink" else None
        x = int(coord[1:])
        y = string.ascii_uppercase.index(coord[0])
        return TurnResult(who, x, y, shot, size)


def placement_valid(placement, occupied) -> bool:
    for idx in range(placement.size):
        (x, y) = (
            (placement.x + idx, placement.y)
            if placement.orientation == "horizontal"
            else (placement.x, placement.y + idx)
        )
        if x > 9 or y > 9:
            return False

        i = y * 10 + x
        if occupied[i]:
            return False

        occupied[i] = True
    return True


def random_placements() -> Placements:
    placements = []
    occupied = [False] * 100

    for size in [5, 4, 3, 3, 2]:
        while True:
            placement = Placement.random(size)
            new_occupied = copy(occupied)
            if not placement_valid(placement, new_occupied):
                continue

            occupied = new_occupied
            placements.append(placement)
            break

    return Placements(placements)


def wait_message(event: str) -> str:
    while True:
        line = input()
        if event in line:
            return line


def log(message: str) -> None:
    print(message, file=sys.stderr)
        

def play_game() -> None:
    log("py: starting game")
    wait_message("game-start")
    wait_message("place-ships")
    placements = random_placements()
    print(placements, flush=True)

    moves = [
        Move(x, y)
        for x in range(10)
        for y in range(10)
    ]
    random.shuffle(moves)
    while True:
        line = input()
        if "take-turn" in line:
            move = moves.pop()
            if RANDOM_SLEEP and random.random() > 0.5:
                sleep(1.5)
                
            print(move, flush=True)
        elif "turn-result" in line:
            turn_result = TurnResult.parse(line)
            log(f"py: got {turn_result}")
        elif "win" in line:
            log("py: won!")
            return
        elif "lose" in line:
            log("py: lose...")
            return
        else:
            log(f"py: unrecognized: {line}")
        


if __name__ == "__main__":
    wait_message("round-start")
    print("round-start", flush=True)
    while True:
        play_game()

